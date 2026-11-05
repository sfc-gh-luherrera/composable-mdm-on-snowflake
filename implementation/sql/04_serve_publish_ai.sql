-- =============================================================================
-- 04_serve_publish_ai.sql
-- Consumption surfaces, each fed from mastered state (never from the pipeline):
--   SERVE_ACCOUNT_LOOKUP  Hybrid Table for sub-second duplicate checks (ADR-016)
--   PUB_*                 stable published contracts for BI / data products
--   SV_ACCOUNT_MDM        semantic view for Cortex Agents / Analyst
--   TASK_RESOLVE_ACCOUNTS triggered task: resolve as soon as RAW receives events
-- =============================================================================

-- ---------- Low-latency serving layer (Hybrid Table: enforced PK + index)
CREATE OR REPLACE HYBRID TABLE SERVE_ACCOUNT_LOOKUP (
    lookup_key      STRING NOT NULL PRIMARY KEY,   -- 'TAX:<id>' or 'SRC:<system>|<id>'
    entity_id       STRING NOT NULL,
    legal_name      STRING,
    country         STRING,
    master_version  NUMBER,
    refreshed_at    TIMESTAMP_NTZ,
    INDEX idx_entity (entity_id)
);

CREATE OR REPLACE PROCEDURE SP_REFRESH_SERVING()
RETURNS NUMBER
LANGUAGE SQL
AS
$$
BEGIN
    BEGIN TRANSACTION;
    DELETE FROM SERVE_ACCOUNT_LOOKUP;
    INSERT INTO SERVE_ACCOUNT_LOOKUP
        SELECT 'TAX:' || g.tax_id, g.entity_id, g.legal_name, g.country, g.master_version, CURRENT_TIMESTAMP()
        FROM GOLD_ACCOUNT g WHERE g.tax_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY g.tax_id ORDER BY g.master_version DESC, g.entity_id) = 1
        UNION ALL
        SELECT 'SRC:' || x.source_system || '|' || x.source_record_id, g.entity_id, g.legal_name, g.country,
               g.master_version, CURRENT_TIMESTAMP()
        FROM CORE_ENTITY_XREF x JOIN GOLD_ACCOUNT g ON g.entity_id = x.entity_id;
    COMMIT;
    RETURN (SELECT COUNT(*) FROM SERVE_ACCOUNT_LOOKUP);
END;
$$;

-- ---------- Published contracts (secure views; consumers never read internal tables)
CREATE OR REPLACE SECURE VIEW PUB_ACCOUNT_360 AS
SELECT entity_id, master_version, legal_name, tax_id, email, phone, street, postal_code, country,
       source_record_count, updated_at
FROM GOLD_ACCOUNT;

CREATE OR REPLACE SECURE VIEW PUB_ACCOUNT_LINEAGE AS
SELECT p.entity_id, p.attribute_name, p.won_by, p.rule_version, p.strategy,
       p.source_system, p.source_record_id, p.source_updated_at
FROM GOLD_ACCOUNT_PROVENANCE p;

CREATE OR REPLACE SECURE VIEW PUB_MDM_QUALITY AS
SELECT
    (SELECT COUNT(*) FROM CORE_ENTITY WHERE status = 'ACTIVE')                        AS active_masters,
    (SELECT COUNT(*) FROM CORE_ENTITY_XREF)                                            AS linked_source_records,
    (SELECT COUNT(*) FROM GOV_STEWARDSHIP_CASE WHERE status = 'OPEN')                  AS open_cases,
    (SELECT COUNT(*) FROM CORE_MATCH_DECISION WHERE decision_type = 'AUTO_LINK')       AS auto_links,
    (SELECT COUNT(*) FROM CORE_MATCH_DECISION WHERE decision_type = 'STEWARD_MERGE')   AS steward_merges,
    (SELECT COUNT(*) FROM CORE_MATCH_DECISION WHERE decision_type = 'UNMERGE')         AS unmerges,
    (SELECT COUNT(*) FROM GOV_ERASURE_REQUEST WHERE status = 'COMPLETED')              AS erasures_completed;

-- ---------- Semantic view: governed structured access for Cortex Agents
CREATE OR REPLACE SEMANTIC VIEW SV_ACCOUNT_MDM
  TABLES (
    accounts AS GOLD_ACCOUNT PRIMARY KEY (entity_id)
      WITH SYNONYMS = ('golden accounts', 'master accounts', 'customers')
      COMMENT = 'Current golden record per mastered account',
    lineage AS GOLD_ACCOUNT_PROVENANCE PRIMARY KEY (entity_id, attribute_name)
      COMMENT = 'Which source value and rule won for each golden attribute'
  )
  RELATIONSHIPS (
    lineage_to_account AS lineage (entity_id) REFERENCES accounts
  )
  DIMENSIONS (
    accounts.legal_name  AS accounts.legal_name  COMMENT = 'Surviving legal name',
    accounts.country     AS accounts.country     COMMENT = 'ISO country code',
    accounts.tax_id      AS accounts.tax_id      COMMENT = 'Validated tax identifier',
    lineage.attribute    AS lineage.attribute_name,
    lineage.won_by       AS lineage.won_by       COMMENT = 'RULE or STEWARD_OVERRIDE',
    lineage.source       AS lineage.source_system
  )
  METRICS (
    accounts.master_count     AS COUNT(accounts.entity_id)           COMMENT = 'Number of active masters',
    accounts.avg_sources      AS AVG(accounts.source_record_count)   COMMENT = 'Average source records per master',
    lineage.override_count    AS COUNT_IF(lineage.won_by = 'STEWARD_OVERRIDE')
  )
  COMMENT = 'Composable MDM: mastered accounts and attribute provenance';

-- ---------- Event-driven resolution: triggered task (no schedule; runs when RAW has data)
CREATE OR REPLACE STREAM RAW_ACCOUNT_EVENTS_STREAM ON TABLE RAW_ACCOUNT_EVENTS APPEND_ONLY = TRUE;

CREATE OR REPLACE TABLE GOV_PIPELINE_RUN (
    run_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    events_consumed NUMBER
);

CREATE OR REPLACE PROCEDURE SP_PIPELINE_TICK()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    res VARIANT;
BEGIN
    -- DML on the stream advances its offset; then resolve and refresh serving
    INSERT INTO GOV_PIPELINE_RUN (events_consumed) SELECT COUNT(*) FROM RAW_ACCOUNT_EVENTS_STREAM;
    CALL SP_RESOLVE_ACCOUNTS('v1') INTO :res;
    CALL SP_REFRESH_SERVING();
    RETURN res;
END;
$$;

CREATE OR REPLACE TASK TASK_RESOLVE_ACCOUNTS
    WAREHOUSE = {{WAREHOUSE}}
    WHEN SYSTEM$STREAM_HAS_DATA('RAW_ACCOUNT_EVENTS_STREAM')
AS
    CALL SP_PIPELINE_TICK();
-- Task is created SUSPENDED. Production: ALTER TASK TASK_RESOLVE_ACCOUNTS RESUME;
