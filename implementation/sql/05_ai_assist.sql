-- =============================================================================
-- 05_ai_assist.sql  (optional)
-- AI recommends; stewards and policy decide (ADR-012).
-- For each OPEN stewardship case, computes a semantic similarity signal and an
-- LLM recommendation with a short rationale. Results are evidence only: this
-- procedure has no write path to CORE_*, XREF or GOLD. Every recommendation is
-- persisted with model, prompt version and inputs hash for audit.
-- Placeholder {{AI_MODEL}} is substituted by the runner (default claude-sonnet-4-6).
-- =============================================================================

CREATE OR REPLACE TABLE GOV_AI_RECOMMENDATION (
    recommendation_id   STRING NOT NULL PRIMARY KEY,
    case_id             STRING NOT NULL,
    model               STRING NOT NULL,
    prompt_version      STRING NOT NULL,
    inputs_hash         STRING NOT NULL,
    semantic_similarity FLOAT,
    recommendation      STRING,            -- LIKELY_SAME | LIKELY_DIFFERENT | UNSURE
    rationale           STRING,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE VIEW GOV_CASE_EVIDENCE AS
SELECT s.case_id, c.candidate_id, c.score AS rule_score,
       l.legal_name AS left_name, l.postal_code AS left_postal, l.tax_id AS left_tax_id, l.country AS left_country,
       g.legal_name AS right_name, g.postal_code AS right_postal, g.tax_id AS right_tax_id, g.country AS right_country
FROM GOV_STEWARDSHIP_CASE s
JOIN CORE_MATCH_CANDIDATE c ON c.candidate_id = s.candidate_id
JOIN PREP_ACCOUNT_STD l ON l.source_system = c.left_system AND l.source_record_id = c.left_record_id
JOIN GOLD_ACCOUNT g ON g.entity_id = c.right_entity_id
WHERE s.status = 'OPEN';

CREATE OR REPLACE PROCEDURE SP_AI_RECOMMEND(MAX_CASES NUMBER)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO GOV_AI_RECOMMENDATION (recommendation_id, case_id, model, prompt_version, inputs_hash,
                                       semantic_similarity, recommendation, rationale)
    WITH todo AS (
        SELECT e.* FROM GOV_CASE_EVIDENCE e
        WHERE NOT EXISTS (SELECT 1 FROM GOV_AI_RECOMMENDATION r WHERE r.case_id = e.case_id)
        ORDER BY e.case_id
        LIMIT :MAX_CASES
    ), scored AS (
        SELECT t.*,
               AI_SIMILARITY(t.left_name || ', ' || COALESCE(t.left_postal, ''),
                             t.right_name || ', ' || COALESCE(t.right_postal, '')) AS sim,
               AI_COMPLETE(
                   model => '{{AI_MODEL}}',
                   prompt => 'You assist a master-data steward. Decide whether two business records describe the '
                          || 'same legal entity. Different tax ids mean different entities. Answer only from the evidence. '
                          || 'Record A: name=' || t.left_name || '; postal=' || COALESCE(t.left_postal, 'n/a')
                          || '; tax_id=' || COALESCE(t.left_tax_id, 'n/a') || '; country=' || COALESCE(t.left_country, 'n/a')
                          || '. Record B: name=' || t.right_name || '; postal=' || COALESCE(t.right_postal, 'n/a')
                          || '; tax_id=' || COALESCE(t.right_tax_id, 'n/a') || '; country=' || COALESCE(t.right_country, 'n/a') || '.',
                   response_format => {
                       'type': 'json',
                       'schema': {'type': 'object',
                                  'properties': {'recommendation': {'type': 'string',
                                                     'enum': ['LIKELY_SAME', 'LIKELY_DIFFERENT', 'UNSURE']},
                                                 'rationale': {'type': 'string'}},
                                  'required': ['recommendation', 'rationale']}}
               ) AS ai
        FROM todo t
    )
    SELECT UUID_STRING(), case_id, '{{AI_MODEL}}', 'case-reco-v1',
           SHA2(left_name || '|' || right_name || '|' || COALESCE(left_postal, '') || '|' || COALESCE(right_postal, '')),
           sim, ai:recommendation::STRING, ai:rationale::STRING
    FROM scored;
    RETURN SQLROWCOUNT;
END;
$$;
