-- =============================================================================
-- seed_golden_dataset.sql
-- Synthetic golden dataset with ground truth (payload:_truth_id) used ONLY by tests.
-- {{N}} true entities, each with a CRM record and (for ~70%) an ERP duplicate.
-- Noise: ~60% of duplicates carry the tax id (deterministic link), the rest only a
-- name variant + same postal code (must go to a steward, never auto-merge).
-- ~5% of entities are "near twins": a different real company with a similar name
-- at the same postal code and a different tax id (false-merge trap).
-- =============================================================================
INSERT INTO RAW_ACCOUNT_EVENTS (event_id, event_timestamp, source_system, source_record_id,
                                source_updated_at, operation, correlation_id, payload)
WITH base AS (
    SELECT SEQ4() AS i,
           ARRAY_CONSTRUCT('Alpha','Beta','Gamma','Delta','Omega','Nova','Terra','Vertex','Helix','Lumen')[UNIFORM(0,9,RANDOM(11))]::STRING
             || ' ' || ARRAY_CONSTRUCT('Logistics','Foods','Energy','Textiles','Pharma','Motors','Media','Labs','Retail','Capital')[UNIFORM(0,9,RANDOM(12))]::STRING
             || ' ' || TO_CHAR(SEQ4())                                AS company,
           'T' || LPAD(TO_CHAR(SEQ4()), 8, '0')                        AS tax_id,
           LPAD(TO_CHAR(10000 + SEQ4()), 6, '0')                       AS postal_code,
           ARRAY_CONSTRUCT('ES','FR','DE','IT','PT','GB')[MOD(SEQ4(), 6)]::STRING AS country,
           UNIFORM(0, 99, RANDOM(13)) AS r_dup,
           UNIFORM(0, 99, RANDOM(14)) AS r_tax,
           UNIFORM(0, 99, RANDOM(15)) AS r_twin
    FROM TABLE(GENERATOR(ROWCOUNT => {{N}}))
), recs AS (
    -- CRM record (always present)
    SELECT i, 'CRM' AS src, 'GC-' || i AS rid, i AS truth, company || ' S.A.' AS name,
           IFF(r_tax < 80, tax_id, NULL) AS tax, postal_code, country,
           LOWER(REPLACE(company, ' ', '.')) || '@example.com' AS email
    FROM base
    UNION ALL
    -- ERP duplicate (~70%)
    SELECT i, 'ERP', 'GE-' || i, i, UPPER(company) || ' SA',
           IFF(r_tax < 60, tax_id, NULL), postal_code, country, NULL
    FROM base WHERE r_dup < 70
    UNION ALL
    -- near twin: different real entity, similar name, same postal, different tax id (~5%)
    SELECT i, 'ERP', 'GT-' || i, 1000000 + i, company || ' Holding', 'X' || tax_id, postal_code, country, NULL
    FROM base WHERE r_twin < 5
)
SELECT UUID_STRING(), DATEADD(second, i, '2026-01-01'::TIMESTAMP_NTZ), src, rid,
       DATEADD(second, i, '2026-01-01'::TIMESTAMP_NTZ), 'UPSERT', 'golden-seed',
       OBJECT_CONSTRUCT('legal_name', name, 'tax_id', tax, 'postal_code', postal_code, 'country', country,
                        'email', email, '_truth_id', truth)
FROM recs;
