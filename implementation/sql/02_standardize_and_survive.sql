-- =============================================================================
-- 02_standardize_and_survive.sql
-- Standardization (Dynamic Table) + survivorship and provenance (views).
-- Identity resolution is NOT done here (see 03): this layer only decides which
-- source value wins for an already-resolved master (ADR-006).
-- Placeholder {{WAREHOUSE}} is substituted by the runner.
-- =============================================================================

-- Latest state per source record, normalized. Erased records are excluded by hash,
-- so a late event for an erased subject never re-enters mastering.
CREATE OR REPLACE DYNAMIC TABLE PREP_ACCOUNT_STD
    TARGET_LAG = '1 minute'
    WAREHOUSE  = {{WAREHOUSE}}
    REFRESH_MODE = FULL
    COMMENT = 'Standardized latest source state per record. Versioned, testable normalization.'
AS
WITH latest AS (
    SELECT *
    FROM RAW_ACCOUNT_EVENTS
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY source_system, source_record_id
        ORDER BY source_updated_at DESC, event_timestamp DESC, event_id DESC) = 1
)
SELECT
    l.source_system,
    l.source_record_id,
    l.source_updated_at,
    l.event_id                                                       AS last_event_id,
    l.operation = 'DELETE'                                           AS is_deleted,
    SHA2(l.source_system || '|' || l.source_record_id)               AS record_hash,
    NULLIF(TRIM(l.payload:legal_name::STRING), '')                   AS legal_name,
    -- match key: upper-case, punctuation removed, common legal suffixes stripped
    TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(UPPER(l.payload:legal_name::STRING), '[^A-Z0-9 ]', ''),
        '\\b(SA|SL|SLU|LTD|LIMITED|INC|GMBH|BV|SAS|SPA|LLC|PLC|CORP|CORPORATION|CO)\\b', '')) AS name_key,
    NULLIF(UPPER(REGEXP_REPLACE(l.payload:tax_id::STRING, '[^A-Za-z0-9]', '')), '') AS tax_id,
    NULLIF(LOWER(TRIM(l.payload:email::STRING)), '')                 AS email,
    NULLIF(REGEXP_REPLACE(l.payload:phone::STRING, '[^0-9+]', ''), '') AS phone,
    NULLIF(TRIM(l.payload:street::STRING), '')                       AS street,
    NULLIF(UPPER(REPLACE(l.payload:postal_code::STRING, ' ', '')), '') AS postal_code,
    NULLIF(UPPER(TRIM(l.payload:country::STRING)), '')               AS country
FROM latest l
WHERE NOT EXISTS (
    SELECT 1 FROM GOV_ERASURE_SUPPRESSION s
    WHERE s.record_hash = SHA2(l.source_system || '|' || l.source_record_id));

-- All candidate attribute values for each ACTIVE master, ranked by the active survivorship rule.
CREATE OR REPLACE VIEW GOLD_ACCOUNT_ATTRIBUTE_CANDIDATES AS
WITH unpivoted AS (
    SELECT source_system, source_record_id, source_updated_at, attribute_name, attribute_value
    FROM (SELECT source_system, source_record_id, source_updated_at,
                 legal_name, tax_id, email, phone, street, postal_code, country
          FROM PREP_ACCOUNT_STD WHERE NOT is_deleted)
    UNPIVOT (attribute_value FOR attribute_name IN
        (legal_name, tax_id, email, phone, street, postal_code, country))
), vals AS (
    SELECT x.entity_id, u.source_system, u.source_record_id, u.source_updated_at,
           u.attribute_name, u.attribute_value
    FROM unpivoted u
    JOIN CORE_ENTITY_XREF x
      ON x.source_system = u.source_system AND x.source_record_id = u.source_record_id
    JOIN CORE_ENTITY e ON e.entity_id = x.entity_id AND e.status = 'ACTIVE'
)
SELECT v.*,
       r.rule_version, r.strategy,
       ROW_NUMBER() OVER (
           PARTITION BY v.entity_id, v.attribute_name
           ORDER BY IFF(r.strategy = 'SOURCE_PRIORITY',
                        ARRAY_POSITION(v.source_system::VARIANT, r.source_priority), NULL) ASC NULLS LAST,
                    v.source_updated_at DESC,
                    v.source_system, v.source_record_id) AS rank_in_policy
FROM vals v
JOIN GOV_SURVIVORSHIP_RULE r
  ON LOWER(r.attribute_name) = LOWER(v.attribute_name) AND r.is_active;

-- Provenance: which source value and rule won for every published attribute.
-- Steward overrides always win and are recorded as such.
CREATE OR REPLACE VIEW GOLD_ACCOUNT_PROVENANCE AS
SELECT c.entity_id, LOWER(c.attribute_name) AS attribute_name, c.attribute_value,
       'RULE' AS won_by, c.rule_version, c.strategy,
       c.source_system, c.source_record_id, c.source_updated_at
FROM GOLD_ACCOUNT_ATTRIBUTE_CANDIDATES c
WHERE c.rank_in_policy = 1
  AND NOT EXISTS (SELECT 1 FROM GOV_ATTRIBUTE_OVERRIDE o
                  WHERE o.entity_id = c.entity_id AND o.attribute_name = LOWER(c.attribute_name))
UNION ALL
SELECT o.entity_id, o.attribute_name, o.override_value,
       'STEWARD_OVERRIDE', NULL, NULL, NULL, o.command_id, o.created_at
FROM GOV_ATTRIBUTE_OVERRIDE o
JOIN CORE_ENTITY e ON e.entity_id = o.entity_id AND e.status = 'ACTIVE';

-- Golden record: current approved canonical representation.
CREATE OR REPLACE VIEW GOLD_ACCOUNT AS
SELECT e.entity_id,
       e.master_version,
       MAX(IFF(p.attribute_name = 'legal_name',  p.attribute_value, NULL)) AS legal_name,
       MAX(IFF(p.attribute_name = 'tax_id',      p.attribute_value, NULL)) AS tax_id,
       MAX(IFF(p.attribute_name = 'email',       p.attribute_value, NULL)) AS email,
       MAX(IFF(p.attribute_name = 'phone',       p.attribute_value, NULL)) AS phone,
       MAX(IFF(p.attribute_name = 'street',      p.attribute_value, NULL)) AS street,
       MAX(IFF(p.attribute_name = 'postal_code', p.attribute_value, NULL)) AS postal_code,
       MAX(IFF(p.attribute_name = 'country',     p.attribute_value, NULL)) AS country,
       COALESCE(xc.n, 0) AS source_record_count,
       e.updated_at
FROM CORE_ENTITY e
LEFT JOIN GOLD_ACCOUNT_PROVENANCE p ON p.entity_id = e.entity_id
LEFT JOIN (SELECT entity_id, COUNT(*) AS n FROM CORE_ENTITY_XREF GROUP BY entity_id) xc
       ON xc.entity_id = e.entity_id
WHERE e.status = 'ACTIVE'
GROUP BY e.entity_id, e.master_version, e.updated_at, xc.n;
