-- =============================================================================
-- 03_mastering_engine.sql
-- Identity resolution + the governed command path.
--   SP_RESOLVE_ACCOUNTS : links new source records to stable master IDs.
--                         Deterministic rules auto-link; fuzzy evidence only ever
--                         opens a stewardship case (rules before AI, ADR-007).
--   SP_MDM_COMMAND      : the ONLY way stewards, apps or agents change mastered
--                         state. Idempotent on command_id. Every command writes a
--                         decision, a ledger event and an outbound publish row.
-- =============================================================================

CREATE OR REPLACE PROCEDURE SP_PUBLISH_EVENTS(CORRELATION_ID STRING)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO OUT_ACCOUNT_EVENTS_PUBLISH
        (master_event_id, topic, event_type, entity_id, related_entity_id, master_version, correlation_id)
    SELECT m.master_event_id,
           'mdm.account.' || LOWER(REPLACE(m.event_type, 'MASTER_', '')) || '.v1',
           m.event_type, m.entity_id, m.related_entity_id, m.master_version, m.correlation_id
    FROM GOV_MASTER_EVENT m
    WHERE m.correlation_id = :CORRELATION_ID
      AND NOT EXISTS (SELECT 1 FROM OUT_ACCOUNT_EVENTS_PUBLISH o WHERE o.master_event_id = m.master_event_id);
    RETURN SQLROWCOUNT;
END;
$$;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RESOLVE_ACCOUNTS(RULE_VERSION STRING)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    run_id         STRING DEFAULT UUID_STRING();
    fuzzy_threshold NUMBER(5,2);
    n_new          NUMBER DEFAULT 0;
    n_auto         NUMBER DEFAULT 0;
    n_entities     NUMBER DEFAULT 0;
    n_cases        NUMBER DEFAULT 0;
BEGIN
    ALTER DYNAMIC TABLE PREP_ACCOUNT_STD REFRESH;

    fuzzy_threshold := (SELECT MAX(threshold) FROM GOV_MATCH_RULE
                        WHERE rule_version = :RULE_VERSION AND rule_id = 'R2_NAME_POSTAL' AND is_active);

    -- 1. Source records not yet linked to any master
    CREATE OR REPLACE TEMPORARY TABLE TMP_NEW AS
        SELECT p.* FROM PREP_ACCOUNT_STD p
        LEFT JOIN CORE_ENTITY_XREF x
          ON x.source_system = p.source_system AND x.source_record_id = p.source_record_id
        WHERE x.entity_id IS NULL AND NOT p.is_deleted;
    n_new := (SELECT COUNT(*) FROM TMP_NEW);

    -- 2. Deterministic rule R1: exact tax identifier against an existing ACTIVE master
    CREATE OR REPLACE TEMPORARY TABLE TMP_ASSIGN AS
        SELECT n.source_system, n.source_record_id, MIN(x.entity_id) AS entity_id,
               'AUTO_LINK'::STRING AS decision_type, 'R1_TAX_ID_EXACT'::STRING AS rule_id, FALSE AS creates_entity
        FROM TMP_NEW n
        JOIN PREP_ACCOUNT_STD p ON p.tax_id = n.tax_id AND NOT p.is_deleted
        JOIN CORE_ENTITY_XREF x ON x.source_system = p.source_system AND x.source_record_id = p.source_record_id
        JOIN CORE_ENTITY e      ON e.entity_id = x.entity_id AND e.status = 'ACTIVE'
        JOIN GOV_MATCH_RULE r   ON r.rule_version = :RULE_VERSION AND r.rule_id = 'R1_TAX_ID_EXACT'
                               AND r.is_active AND r.auto_merge
        WHERE n.tax_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM GOV_MATCH_SUPPRESSION s
                          WHERE s.source_system = n.source_system AND s.source_record_id = n.source_record_id
                            AND s.entity_id = x.entity_id)
        GROUP BY n.source_system, n.source_record_id;

    -- 3. Everything else gets a NEW stable master. Records in the same batch that share
    --    a tax identifier share one new master (the group leader creates it).
    CREATE OR REPLACE TEMPORARY TABLE TMP_GROUPS AS
        SELECT n.source_system, n.source_record_id,
               FIRST_VALUE(n.source_system || '|' || n.source_record_id) OVER (
                   PARTITION BY COALESCE(n.tax_id, n.source_system || '|' || n.source_record_id)
                   ORDER BY n.source_updated_at, n.source_system, n.source_record_id) AS group_leader
        FROM TMP_NEW n
        WHERE NOT EXISTS (SELECT 1 FROM TMP_ASSIGN a
                          WHERE a.source_system = n.source_system AND a.source_record_id = n.source_record_id);

    CREATE OR REPLACE TEMPORARY TABLE TMP_GROUP_IDS AS
        SELECT group_leader, UUID_STRING() AS entity_id FROM (SELECT DISTINCT group_leader FROM TMP_GROUPS);

    INSERT INTO TMP_ASSIGN
        SELECT g.source_system, g.source_record_id, gi.entity_id,
               IFF(g.source_system || '|' || g.source_record_id = g.group_leader, 'NEW_ENTITY', 'AUTO_LINK'),
               IFF(g.source_system || '|' || g.source_record_id = g.group_leader, NULL, 'R1_TAX_ID_EXACT'),
               g.source_system || '|' || g.source_record_id = g.group_leader
        FROM TMP_GROUPS g JOIN TMP_GROUP_IDS gi ON gi.group_leader = g.group_leader;

    CREATE OR REPLACE TEMPORARY TABLE TMP_ASSIGN_D AS
        SELECT a.*, UUID_STRING() AS decision_id, UUID_STRING() AS master_event_id FROM TMP_ASSIGN a;

    n_auto     := (SELECT COUNT(*) FROM TMP_ASSIGN_D WHERE decision_type = 'AUTO_LINK');
    n_entities := (SELECT COUNT(*) FROM TMP_ASSIGN_D WHERE creates_entity);

    BEGIN TRANSACTION;

    INSERT INTO CORE_ENTITY (entity_id, status, master_version, caused_by_event_id)
        SELECT entity_id, 'ACTIVE', 1, master_event_id FROM TMP_ASSIGN_D WHERE creates_entity;

    -- existing masters that received an auto-link get a new version
    UPDATE CORE_ENTITY e SET master_version = e.master_version + 1, updated_at = CURRENT_TIMESTAMP()
    FROM (SELECT DISTINCT entity_id FROM TMP_ASSIGN_D
          WHERE NOT creates_entity
            AND entity_id NOT IN (SELECT entity_id FROM TMP_ASSIGN_D WHERE creates_entity)) t
    WHERE e.entity_id = t.entity_id;

    INSERT INTO CORE_MATCH_DECISION (decision_id, decision_type, method, rule_version, rule_id, confidence, actor)
        SELECT decision_id, decision_type, 'RULE', :RULE_VERSION, rule_id,
               IFF(decision_type = 'AUTO_LINK', 100, NULL), 'SYSTEM:SP_RESOLVE_ACCOUNTS'
        FROM TMP_ASSIGN_D;

    INSERT INTO CORE_ENTITY_XREF (source_system, source_record_id, entity_id, linked_by_decision)
        SELECT source_system, source_record_id, entity_id, decision_id FROM TMP_ASSIGN_D;

    -- ledger: ids and hashes only, never attribute values
    INSERT INTO GOV_MASTER_EVENT (master_event_id, event_type, entity_id, master_version, decision_id, detail, correlation_id)
        SELECT a.master_event_id,
               IFF(a.creates_entity, 'MASTER_CREATED', 'MASTER_LINKED'),
               a.entity_id, e.master_version, a.decision_id,
               OBJECT_CONSTRUCT('record_hash', SHA2(a.source_system || '|' || a.source_record_id),
                                'source_system', a.source_system,
                                'rule_version', :RULE_VERSION, 'rule_id', a.rule_id),
               :run_id
        FROM TMP_ASSIGN_D a JOIN CORE_ENTITY e ON e.entity_id = a.entity_id;

    -- 4. Fuzzy rule R2 (never auto-merges): similar name key + same postal code, different
    --    masters, no conflicting tax identifiers, not suppressed, no open candidate already.
    CREATE OR REPLACE TEMPORARY TABLE TMP_CAND AS
        SELECT UUID_STRING() AS candidate_id, a.source_system AS left_system, a.source_record_id AS left_record_id,
               a.entity_id AS left_entity_id, xo.entity_id AS right_entity_id,
               MAX(JAROWINKLER_SIMILARITY(n.name_key, o.name_key)) AS score
        FROM TMP_ASSIGN_D a
        JOIN PREP_ACCOUNT_STD n ON n.source_system = a.source_system AND n.source_record_id = a.source_record_id
        JOIN PREP_ACCOUNT_STD o ON o.postal_code = n.postal_code AND NOT o.is_deleted
        JOIN CORE_ENTITY_XREF xo ON xo.source_system = o.source_system AND xo.source_record_id = o.source_record_id
        JOIN CORE_ENTITY eo ON eo.entity_id = xo.entity_id AND eo.status = 'ACTIVE'
        WHERE xo.entity_id <> a.entity_id
          AND JAROWINKLER_SIMILARITY(n.name_key, o.name_key) >= :fuzzy_threshold
          AND NOT (n.tax_id IS NOT NULL AND o.tax_id IS NOT NULL AND n.tax_id <> o.tax_id)
          AND NOT EXISTS (SELECT 1 FROM GOV_MATCH_SUPPRESSION s
                          WHERE s.source_system = a.source_system AND s.source_record_id = a.source_record_id
                            AND s.entity_id = xo.entity_id)
          AND NOT EXISTS (SELECT 1 FROM CORE_MATCH_CANDIDATE c
                          WHERE c.left_system = a.source_system AND c.left_record_id = a.source_record_id
                            AND c.right_entity_id = xo.entity_id AND c.status = 'OPEN')
        GROUP BY a.source_system, a.source_record_id, a.entity_id, xo.entity_id
        -- one case per pair of masters, even when both sides arrived in this batch
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY LEAST(a.entity_id, xo.entity_id), GREATEST(a.entity_id, xo.entity_id)
            ORDER BY a.source_system, a.source_record_id) = 1;

    INSERT INTO CORE_MATCH_CANDIDATE (candidate_id, rule_version, rule_id, left_system, left_record_id,
                                      right_entity_id, score, features, status)
        SELECT candidate_id, :RULE_VERSION, 'R2_NAME_POSTAL', left_system, left_record_id, right_entity_id, score,
               OBJECT_CONSTRUCT('name_similarity', score, 'postal_code_equal', TRUE), 'OPEN'
        FROM TMP_CAND;

    INSERT INTO GOV_STEWARDSHIP_CASE (case_id, case_type, candidate_id, status)
        SELECT UUID_STRING(), 'SUSPECT_MATCH', candidate_id, 'OPEN' FROM TMP_CAND;
    n_cases := SQLROWCOUNT;

    COMMIT;

    CALL SP_PUBLISH_EVENTS(:run_id);

    RETURN OBJECT_CONSTRUCT('run_id', run_id, 'rule_version', RULE_VERSION,
                            'new_records', n_new, 'new_masters', n_entities,
                            'auto_links', n_auto, 'stewardship_cases', n_cases);
END;
$$;

-- -----------------------------------------------------------------------------
-- SP_MDM_COMMAND(command_id, command_type, args, actor)
--   MERGE              {survivor_entity_id, superseded_entity_id, candidate_id?, comment?}
--   UNMERGE            {merge_event_id, comment?}
--   NO_MATCH           {candidate_id, comment?}
--   OVERRIDE_ATTRIBUTE {entity_id, attribute_name, value, reason}
--   ERASE              {entity_id, legal_basis, approved_by}
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_MDM_COMMAND(COMMAND_ID STRING, COMMAND_TYPE STRING, ARGS VARIANT, ACTOR STRING)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    decision_id STRING DEFAULT UUID_STRING();
    result      VARIANT;
    survivor    STRING;
    superseded  STRING;
    entity      STRING;
    cand        STRING;
    hashes      ARRAY;
    n           NUMBER;
    erasure_id  STRING;
    v_comment   STRING DEFAULT ARGS:comment::STRING;
    v_merge_evt STRING DEFAULT ARGS:merge_event_id::STRING;
    v_attr      STRING DEFAULT LOWER(ARGS:attribute_name::STRING);
    v_value     STRING DEFAULT ARGS:value::STRING;
    v_reason    STRING DEFAULT ARGS:reason::STRING;
    v_basis     STRING DEFAULT ARGS:legal_basis::STRING;
    v_approver  STRING DEFAULT ARGS:approved_by::STRING;
BEGIN
    -- Idempotency: a replayed command is acknowledged, never re-executed
    IF (EXISTS (SELECT 1 FROM GOV_COMMAND_LOG WHERE command_id = :COMMAND_ID)) THEN
        RETURN (SELECT OBJECT_INSERT(result, 'replayed', TRUE, TRUE) FROM GOV_COMMAND_LOG WHERE command_id = :COMMAND_ID);
    END IF;

    BEGIN TRANSACTION;

    CASE (COMMAND_TYPE)
    -- ---------------------------------------------------------------- MERGE
    WHEN 'MERGE' THEN
        survivor   := ARGS:survivor_entity_id::STRING;
        superseded := ARGS:superseded_entity_id::STRING;
        n := (SELECT COUNT(*) FROM CORE_ENTITY
              WHERE entity_id IN (:survivor, :superseded) AND status = 'ACTIVE');
        IF (n <> 2 OR survivor = superseded) THEN
            ROLLBACK;
            RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'both masters must be distinct and ACTIVE');
        END IF;

        hashes := (SELECT ARRAY_AGG(SHA2(source_system || '|' || source_record_id))
                   FROM CORE_ENTITY_XREF WHERE entity_id = :superseded);

        INSERT INTO CORE_MATCH_DECISION (decision_id, decision_type, method, actor, comment)
            VALUES (:decision_id, 'STEWARD_MERGE', 'STEWARD', :ACTOR, :v_comment);
        UPDATE CORE_ENTITY_XREF SET entity_id = :survivor, linked_by_decision = :decision_id
            WHERE entity_id = :superseded;
        UPDATE CORE_ENTITY SET status = 'SUPERSEDED', superseded_by = :survivor,
               master_version = master_version + 1, updated_at = CURRENT_TIMESTAMP()
            WHERE entity_id = :superseded;
        UPDATE CORE_ENTITY SET master_version = master_version + 1, updated_at = CURRENT_TIMESTAMP()
            WHERE entity_id = :survivor;

        INSERT INTO GOV_MASTER_EVENT (master_event_id, event_type, entity_id, related_entity_id, master_version,
                                      decision_id, command_id, detail, correlation_id)
            SELECT UUID_STRING(), 'MASTER_MERGED', :survivor, :superseded, master_version, :decision_id, :COMMAND_ID,
                   OBJECT_CONSTRUCT('moved_record_hashes', :hashes), :COMMAND_ID
            FROM CORE_ENTITY WHERE entity_id = :survivor;

        IF (ARGS:candidate_id IS NOT NULL) THEN
            cand := ARGS:candidate_id::STRING;
            UPDATE CORE_MATCH_CANDIDATE SET status = 'ACCEPTED' WHERE candidate_id = :cand;
            UPDATE GOV_STEWARDSHIP_CASE SET status = 'RESOLVED', resolution = 'MERGED',
                   resolved_at = CURRENT_TIMESTAMP(), resolved_by = :ACTOR WHERE candidate_id = :cand;
        END IF;
        result := OBJECT_CONSTRUCT('status', 'OK', 'survivor', survivor, 'superseded', superseded,
                                   'moved_records', ARRAY_SIZE(hashes));

    -- ---------------------------------------------------------------- UNMERGE
    -- Reconstructs from the ledger: only the records the MERGE moved go back; records
    -- added to the survivor after the merge stay. Survivorship recomputes from current
    -- source values for both masters (GOLD views), so post-merge updates are respected.
    WHEN 'UNMERGE' THEN
        IF (NOT EXISTS (SELECT 1 FROM GOV_MASTER_EVENT m JOIN CORE_ENTITY e
                          ON e.entity_id = m.related_entity_id AND e.status = 'SUPERSEDED'
                        WHERE m.master_event_id = :v_merge_evt AND m.event_type = 'MASTER_MERGED')) THEN
            ROLLBACK;
            RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'merge event not found or already reversed');
        END IF;
        SELECT entity_id, related_entity_id, detail:moved_record_hashes::ARRAY
          INTO :survivor, :superseded, :hashes
          FROM GOV_MASTER_EVENT WHERE master_event_id = :v_merge_evt;

        INSERT INTO CORE_MATCH_DECISION (decision_id, decision_type, method, actor, comment)
            VALUES (:decision_id, 'UNMERGE', 'STEWARD', :ACTOR, :v_comment);
        UPDATE CORE_ENTITY_XREF SET entity_id = :superseded, linked_by_decision = :decision_id
            WHERE entity_id = :survivor
              AND ARRAY_CONTAINS(SHA2(source_system || '|' || source_record_id)::VARIANT, :hashes);
        n := SQLROWCOUNT;
        UPDATE CORE_ENTITY SET status = 'ACTIVE', superseded_by = NULL,
               master_version = master_version + 1, updated_at = CURRENT_TIMESTAMP()
            WHERE entity_id = :superseded;
        UPDATE CORE_ENTITY SET master_version = master_version + 1, updated_at = CURRENT_TIMESTAMP()
            WHERE entity_id = :survivor;
        -- never auto-link these records back into the survivor
        INSERT INTO GOV_MATCH_SUPPRESSION (source_system, source_record_id, entity_id, reason)
            SELECT source_system, source_record_id, :survivor, 'UNMERGE'
            FROM CORE_ENTITY_XREF WHERE entity_id = :superseded;

        INSERT INTO GOV_MASTER_EVENT (master_event_id, event_type, entity_id, related_entity_id, master_version,
                                      decision_id, command_id, detail, correlation_id)
            SELECT UUID_STRING(), 'MASTER_UNMERGED', e.entity_id,
                   IFF(e.entity_id = :survivor, :superseded, :survivor), e.master_version,
                   :decision_id, :COMMAND_ID,
                   OBJECT_CONSTRUCT('reverses_event_id', :v_merge_evt), :COMMAND_ID
            FROM CORE_ENTITY e WHERE e.entity_id IN (:survivor, :superseded);
        result := OBJECT_CONSTRUCT('status', 'OK', 'reinstated', superseded, 'records_restored', n);

    -- ---------------------------------------------------------------- NO_MATCH
    WHEN 'NO_MATCH' THEN
        cand := ARGS:candidate_id::STRING;
        IF (NOT EXISTS (SELECT 1 FROM CORE_MATCH_CANDIDATE WHERE candidate_id = :cand AND status = 'OPEN')) THEN
            ROLLBACK;
            RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'candidate not open');
        END IF;
        INSERT INTO CORE_MATCH_DECISION (decision_id, decision_type, method, actor, comment)
            VALUES (:decision_id, 'NO_MATCH', 'STEWARD', :ACTOR, :v_comment);
        UPDATE CORE_MATCH_CANDIDATE SET status = 'REJECTED' WHERE candidate_id = :cand;
        UPDATE GOV_STEWARDSHIP_CASE SET status = 'RESOLVED', resolution = 'NO_MATCH',
               resolved_at = CURRENT_TIMESTAMP(), resolved_by = :ACTOR WHERE candidate_id = :cand;
        INSERT INTO GOV_MATCH_SUPPRESSION (source_system, source_record_id, entity_id, reason)
            SELECT left_system, left_record_id, right_entity_id, 'NO_MATCH'
            FROM CORE_MATCH_CANDIDATE WHERE candidate_id = :cand;
        result := OBJECT_CONSTRUCT('status', 'OK', 'candidate', cand);

    -- ---------------------------------------------------------------- OVERRIDE_ATTRIBUTE
    WHEN 'OVERRIDE_ATTRIBUTE' THEN
        entity := ARGS:entity_id::STRING;
        IF (v_reason IS NULL OR
            NOT EXISTS (SELECT 1 FROM CORE_ENTITY WHERE entity_id = :entity AND status = 'ACTIVE')) THEN
            ROLLBACK;
            RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'ACTIVE master and a reason are required');
        END IF;
        MERGE INTO GOV_ATTRIBUTE_OVERRIDE o
        USING (SELECT :entity AS entity_id, :v_attr AS attribute_name) s
           ON o.entity_id = s.entity_id AND o.attribute_name = s.attribute_name
        WHEN MATCHED THEN UPDATE SET override_value = :v_value, reason = :v_reason,
                                     actor = :ACTOR, command_id = :COMMAND_ID, created_at = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (entity_id, attribute_name, override_value, reason, actor, command_id)
             VALUES (s.entity_id, s.attribute_name, :v_value, :v_reason, :ACTOR, :COMMAND_ID);
        UPDATE CORE_ENTITY SET master_version = master_version + 1, updated_at = CURRENT_TIMESTAMP()
            WHERE entity_id = :entity;
        INSERT INTO GOV_MASTER_EVENT (master_event_id, event_type, entity_id, master_version, command_id, detail, correlation_id)
            SELECT UUID_STRING(), 'ATTRIBUTE_OVERRIDDEN', :entity, master_version, :COMMAND_ID,
                   OBJECT_CONSTRUCT('attribute_name', :v_attr), :COMMAND_ID
            FROM CORE_ENTITY WHERE entity_id = :entity;
        result := OBJECT_CONSTRUCT('status', 'OK', 'entity_id', entity);

    -- ---------------------------------------------------------------- ERASE
    -- Source evidence deleted, master tombstoned (identity kept, payload gone),
    -- hashed suppression kept so late events are not re-mastered. Ledger untouched:
    -- it never held PII. Note: Time Travel / Fail-safe windows are part of the
    -- documented deletion latency.
    WHEN 'ERASE' THEN
        entity := ARGS:entity_id::STRING;
        IF (v_basis IS NULL OR v_approver IS NULL OR v_approver = ACTOR
            OR NOT EXISTS (SELECT 1 FROM CORE_ENTITY WHERE entity_id = :entity AND status = 'ACTIVE')) THEN
            ROLLBACK;
            RETURN OBJECT_CONSTRUCT('status', 'REJECTED',
                   'reason', 'ACTIVE master, legal basis and a separate approver are required');
        END IF;
        erasure_id := UUID_STRING();
        INSERT INTO GOV_ERASURE_SUPPRESSION (record_hash, erasure_request_id)
            SELECT SHA2(source_system || '|' || source_record_id), :erasure_id
            FROM CORE_ENTITY_XREF WHERE entity_id = :entity;
        n := SQLROWCOUNT;
        DELETE FROM RAW_ACCOUNT_EVENTS r USING CORE_ENTITY_XREF x
            WHERE x.entity_id = :entity
              AND r.source_system = x.source_system AND r.source_record_id = x.source_record_id;
        DELETE FROM GOV_ATTRIBUTE_OVERRIDE WHERE entity_id = :entity;
        DELETE FROM CORE_ENTITY_XREF WHERE entity_id = :entity;
        UPDATE CORE_ENTITY SET status = 'TOMBSTONED', master_version = master_version + 1,
               updated_at = CURRENT_TIMESTAMP() WHERE entity_id = :entity;
        INSERT INTO GOV_ERASURE_REQUEST (erasure_request_id, entity_id, legal_basis, approved_by, status, completed_at, evidence)
            SELECT :erasure_id, :entity, :v_basis, :v_approver, 'COMPLETED',
                   CURRENT_TIMESTAMP(), OBJECT_CONSTRUCT('source_records_erased', :n, 'command_id', :COMMAND_ID);
        INSERT INTO GOV_MASTER_EVENT (master_event_id, event_type, entity_id, master_version, command_id, detail, correlation_id)
            SELECT UUID_STRING(), 'MASTER_ERASED', :entity, master_version, :COMMAND_ID,
                   OBJECT_CONSTRUCT('erasure_request_id', :erasure_id), :COMMAND_ID
            FROM CORE_ENTITY WHERE entity_id = :entity;
        result := OBJECT_CONSTRUCT('status', 'OK', 'erasure_request_id', erasure_id, 'source_records_erased', n);

    ELSE
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'unknown command type ' || COMMAND_TYPE);
    END CASE;

    INSERT INTO GOV_COMMAND_LOG (command_id, command_type, actor, args, result)
        SELECT :COMMAND_ID, :COMMAND_TYPE, :ACTOR, :ARGS, :result;
    COMMIT;

    CALL SP_PUBLISH_EVENTS(:COMMAND_ID);
    IF (COMMAND_TYPE = 'ERASE') THEN
        ALTER DYNAMIC TABLE PREP_ACCOUNT_STD REFRESH;
    END IF;
    RETURN result;
END;
$$;
