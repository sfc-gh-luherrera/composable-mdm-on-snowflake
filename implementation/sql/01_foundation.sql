-- =============================================================================
-- 01_foundation.sql
-- Composable MDM reference implementation: core tables.
-- Layers are expressed as table-name prefixes so the demo fits in one schema:
--   RAW_   immutable source evidence (never overwritten)
--   GOV_   policies (versioned rules), ledger, stewardship, erasure
--   CORE_  canonical identity: ENTITY, XREF, candidates, decisions
--   GOLD_  golden record + provenance (views, see 02)
--   SERVE_ low-latency lookup (Hybrid Table, see 04)
--   OUT_   flat publish tables for outbound events (stream source for Openflow)
-- In production split these into schemas MDM_RAW, MDM_GOV, MDM_CORE, ...
-- =============================================================================

-- ---------- RAW: immutable inbound events (shape of the inbound event contract)
CREATE OR REPLACE TABLE RAW_ACCOUNT_EVENTS (
    event_id            STRING        NOT NULL,   -- idempotency + traceability
    event_timestamp     TIMESTAMP_NTZ NOT NULL,   -- business-time ordering
    source_system       STRING        NOT NULL,   -- provenance / authority
    source_record_id    STRING        NOT NULL,   -- crosswalk key
    source_updated_at   TIMESTAMP_NTZ NOT NULL,   -- late-event handling
    operation           STRING        NOT NULL,   -- UPSERT | DELETE
    schema_version      STRING        NOT NULL DEFAULT 'v1',
    correlation_id      STRING,
    payload             VARIANT       NOT NULL,   -- original source evidence
    ingested_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- GOV: versioned, business-owned policy
CREATE OR REPLACE TABLE GOV_MATCH_RULE (
    rule_version        STRING  NOT NULL,
    rule_id             STRING  NOT NULL,
    method              STRING  NOT NULL,  -- EXACT_IDENTIFIER | FUZZY_NAME_POSTAL
    auto_merge          BOOLEAN NOT NULL,  -- may this rule link without a steward?
    threshold           NUMBER(5,2),       -- similarity threshold (0-100) for fuzzy rules
    owner               STRING  NOT NULL,
    effective_from      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    is_active           BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (rule_version, rule_id)
);

CREATE OR REPLACE TABLE GOV_SURVIVORSHIP_RULE (
    rule_version        STRING  NOT NULL,
    attribute_name      STRING  NOT NULL,
    strategy            STRING  NOT NULL,  -- SOURCE_PRIORITY | MOST_RECENT
    source_priority     ARRAY,             -- ordered list of source systems
    owner               STRING  NOT NULL,
    is_active           BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (rule_version, attribute_name)
);

-- ---------- CORE: canonical identity (stable IDs, never recomputed)
CREATE OR REPLACE TABLE CORE_ENTITY (
    entity_id           STRING NOT NULL PRIMARY KEY,   -- UUID, assigned once
    entity_type         STRING NOT NULL DEFAULT 'ACCOUNT',
    status              STRING NOT NULL,               -- ACTIVE | SUPERSEDED | TOMBSTONED
    master_version      NUMBER NOT NULL DEFAULT 1,
    superseded_by       STRING,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    caused_by_event_id  STRING
);

CREATE OR REPLACE TABLE CORE_ENTITY_XREF (
    source_system       STRING NOT NULL,
    source_record_id    STRING NOT NULL,
    entity_id           STRING NOT NULL,
    linked_by_decision  STRING NOT NULL,
    linked_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (source_system, source_record_id)
);

CREATE OR REPLACE TABLE CORE_MATCH_CANDIDATE (
    candidate_id        STRING NOT NULL PRIMARY KEY,
    rule_version        STRING NOT NULL,
    rule_id             STRING NOT NULL,
    left_system         STRING NOT NULL,
    left_record_id      STRING NOT NULL,
    right_entity_id     STRING NOT NULL,
    score               NUMBER(5,2),
    features            VARIANT,          -- explainable signals (no raw PII)
    status              STRING NOT NULL,  -- OPEN | ACCEPTED | REJECTED
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CORE_MATCH_DECISION (
    decision_id         STRING NOT NULL PRIMARY KEY,
    decision_type       STRING NOT NULL,  -- NEW_ENTITY | AUTO_LINK | STEWARD_MERGE | UNMERGE | NO_MATCH
    method              STRING NOT NULL,  -- RULE | STEWARD | AI_ASSISTED
    rule_version        STRING,
    rule_id             STRING,
    confidence          NUMBER(5,2),
    actor               STRING NOT NULL,
    comment             STRING,
    decided_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- GOV: immutable decision ledger. References and hashes only, NEVER PII (ADR-015)
CREATE OR REPLACE TABLE GOV_MASTER_EVENT (
    master_event_id     STRING NOT NULL PRIMARY KEY,
    event_type          STRING NOT NULL,  -- MASTER_CREATED | MASTER_LINKED | MASTER_MERGED | MASTER_UNMERGED | ATTRIBUTE_OVERRIDDEN | MASTER_ERASED
    entity_id           STRING NOT NULL,
    related_entity_id   STRING,
    master_version      NUMBER,
    decision_id         STRING,
    command_id          STRING,
    detail              VARIANT,          -- ids, hashes, rule versions; no attribute values
    correlation_id      STRING,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- GOV: stewardship, overrides, suppressions, erasure, command idempotency
CREATE OR REPLACE TABLE GOV_STEWARDSHIP_CASE (
    case_id             STRING NOT NULL PRIMARY KEY,
    case_type           STRING NOT NULL,  -- SUSPECT_MATCH
    candidate_id        STRING,
    status              STRING NOT NULL,  -- OPEN | RESOLVED
    resolution          STRING,
    opened_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    resolved_at         TIMESTAMP_NTZ,
    resolved_by         STRING
);

CREATE OR REPLACE TABLE GOV_ATTRIBUTE_OVERRIDE (
    entity_id           STRING NOT NULL,
    attribute_name      STRING NOT NULL,
    override_value      STRING,
    reason              STRING NOT NULL,
    actor               STRING NOT NULL,
    command_id          STRING NOT NULL,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (entity_id, attribute_name)
);

-- Pairs that must never be auto-linked again (set by NO_MATCH and UNMERGE)
CREATE OR REPLACE TABLE GOV_MATCH_SUPPRESSION (
    source_system       STRING NOT NULL,
    source_record_id    STRING NOT NULL,
    entity_id           STRING NOT NULL,
    reason              STRING NOT NULL,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Hashed keys of erased source records: survives erasure so late events are not re-mastered
CREATE OR REPLACE TABLE GOV_ERASURE_SUPPRESSION (
    record_hash         STRING NOT NULL PRIMARY KEY,
    erasure_request_id  STRING NOT NULL,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE GOV_ERASURE_REQUEST (
    erasure_request_id  STRING NOT NULL PRIMARY KEY,
    entity_id           STRING NOT NULL,
    legal_basis         STRING NOT NULL,
    approved_by         STRING NOT NULL,
    status              STRING NOT NULL,
    completed_at        TIMESTAMP_NTZ,
    evidence            VARIANT
);

CREATE OR REPLACE TABLE GOV_COMMAND_LOG (
    command_id          STRING NOT NULL PRIMARY KEY,   -- replay-safe idempotency key
    command_type        STRING NOT NULL,
    actor               STRING NOT NULL,
    args                VARIANT,
    result              VARIANT,
    executed_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- OUT: one flat table per outbound topic (Openflow Snowflake-to-Kafka source)
CREATE OR REPLACE TABLE OUT_ACCOUNT_EVENTS_PUBLISH (
    master_event_id     STRING NOT NULL,
    topic               STRING NOT NULL,   -- e.g. mdm.account.merged.v1
    schema_version      STRING NOT NULL DEFAULT 'v1',
    event_type          STRING NOT NULL,
    entity_id           STRING NOT NULL,
    related_entity_id   STRING,
    master_version      NUMBER,
    correlation_id      STRING,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- The Openflow connector consumes exactly one stream; one stream per topic table.
CREATE OR REPLACE STREAM OUT_ACCOUNT_EVENTS_PUBLISH_STREAM
    ON TABLE OUT_ACCOUNT_EVENTS_PUBLISH APPEND_ONLY = TRUE;

-- ---------- Seed policy (version v1). Owners are roles, not people.
INSERT INTO GOV_MATCH_RULE (rule_version, rule_id, method, auto_merge, threshold, owner) VALUES
    ('v1', 'R1_TAX_ID_EXACT',   'EXACT_IDENTIFIER',  TRUE,  NULL, 'MDM_PRODUCT_OWNER'),
    ('v1', 'R2_NAME_POSTAL',    'FUZZY_NAME_POSTAL', FALSE, 90,   'MDM_PRODUCT_OWNER');

INSERT INTO GOV_SURVIVORSHIP_RULE (rule_version, attribute_name, strategy, source_priority, owner)
    SELECT 'v1', 'legal_name',   'SOURCE_PRIORITY', ARRAY_CONSTRUCT('ERP','CRM'), 'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'tax_id',       'SOURCE_PRIORITY', ARRAY_CONSTRUCT('ERP','CRM'), 'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'email',        'MOST_RECENT',     NULL,                         'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'phone',        'MOST_RECENT',     NULL,                         'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'street',       'SOURCE_PRIORITY', ARRAY_CONSTRUCT('ERP','CRM'), 'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'postal_code',  'SOURCE_PRIORITY', ARRAY_CONSTRUCT('ERP','CRM'), 'MDM_PRODUCT_OWNER' UNION ALL
    SELECT 'v1', 'country',      'SOURCE_PRIORITY', ARRAY_CONSTRUCT('ERP','CRM'), 'MDM_PRODUCT_OWNER';
