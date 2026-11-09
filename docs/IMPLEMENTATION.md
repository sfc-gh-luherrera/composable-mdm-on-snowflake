# Reference implementation

A compact, **tested** Snowflake-native implementation of the mastering model in the blueprint, for one domain (Account / organization). It is a starting point for a proof of concept — not a production product. It is intentionally SQL-first (SQL scripting procedures, Dynamic Tables, views) so it is easy to read, review and port to dbt or DCM Projects.

## Base work

This work builds on [zbrainiac-labs/MasterDataManagement](https://github.com/zbrainiac-labs/MasterDataManagement) by Marcel Däppen ([article](https://medium.com/@marcel.daeppen_74522/master-data-management-mdm-with-snowflake-native-features-01b27456039f)), a Snowflake-native MDM reference that served as the base for this kit: its Dynamic Table pipeline, matching signals, survivorship approach, Kafka in/out engine, cluster split with suppressions, Streamlit viewers and test-data generator shaped the design here. The code in this repository is an independent re-implementation (the original repository has no LICENSE file, so no code was copied) that extends that base with stable XREF, versioned rules, a PII-free decision ledger, ledger-based unmerge, governed commands and erasure. See [REFERENCE_REVIEW.md](REFERENCE_REVIEW.md) for what was reused and what was extended.

## What it demonstrates

| Blueprint requirement | Where | Test |
|---|---|---|
| Immutable event landing with the inbound contract | `RAW_ACCOUNT_EVENTS` | T01 |
| Versioned, testable standardization | `PREP_ACCOUNT_STD` (Dynamic Table) | T02 |
| Stable master IDs, never recomputed (ADR-008) | `CORE_ENTITY`, `CORE_ENTITY_XREF`, UUIDs assigned once | T05 |
| Rules before AI; deterministic auto-link only | `SP_RESOLVE_ACCOUNTS`, rule `R1_TAX_ID_EXACT` | T02, G01 |
| Fuzzy evidence never auto-merges (ADR-007) | rule `R2_NAME_POSTAL` → `CORE_MATCH_CANDIDATE` + `GOV_STEWARDSHIP_CASE` | T03, G03 |
| False-merge guard (conflicting identifiers) | `SP_RESOLVE_ACCOUNTS` step 4 | T04 |
| Versioned, business-owned policies (ADR-009) | `GOV_MATCH_RULE`, `GOV_SURVIVORSHIP_RULE` (`rule_version`, `owner`) | T06 |
| Survivorship separate from identity (ADR-006) + provenance | `GOLD_ACCOUNT_PROVENANCE`, `GOLD_ACCOUNT` | T06, T07 |
| Decision ledger without PII (ADR-015) | `GOV_MASTER_EVENT` (hashes and ids only) | T08 |
| Command path, never direct edits (ADR-014) | `SP_MDM_COMMAND` | T09–T19 |
| Replay-safe idempotency | `GOV_COMMAND_LOG` on `command_id` | T10 |
| Ledger-based unmerge incl. post-merge updates (§7.5) | `SP_MDM_COMMAND('UNMERGE')` | T12–T14 |
| Steward override with provenance | `GOV_ATTRIBUTE_OVERRIDE` | T16 |
| Erasure with separate approver, tombstone, late-event suppression | `SP_MDM_COMMAND('ERASE')`, `GOV_ERASURE_SUPPRESSION` | T17–T19 |
| One flat publish table per topic + stream for Openflow (ADR-013) | `OUT_ACCOUNT_EVENTS_PUBLISH(_STREAM)` | T20 |
| Low-latency serving layer (ADR-016) | `SERVE_ACCOUNT_LOOKUP` (Hybrid Table) | T21 |
| Governed structured access for agents | `SV_ACCOUNT_MDM` (semantic view) | T22 |
| Event-driven processing | `RAW_ACCOUNT_EVENTS_STREAM` + triggered `TASK_RESOLVE_ACCOUNTS` | T23 |
| Golden-dataset metrics (§15) | `tests/seed_golden_dataset.sql` + `run.py` | G01–G04 |
| AI recommends, never decides (ADR-012) | `SP_AI_RECOMMEND` (`AI_SIMILARITY` + `AI_COMPLETE`) → `GOV_AI_RECOMMENDATION` | G05–G06 |

Latest results: [`implementation/tests/RESULTS.md`](../implementation/tests/RESULTS.md) — **29/29 passed**.

## Layout

```text
implementation/
├── sql/
│   ├── 01_foundation.sql            tables, stream, seed policy v1
│   ├── 02_standardize_and_survive.sql  Dynamic Table + survivorship/provenance/golden views
│   ├── 03_mastering_engine.sql      SP_RESOLVE_ACCOUNTS, SP_MDM_COMMAND, SP_PUBLISH_EVENTS
│   ├── 04_serve_publish_ai.sql      Hybrid Table serving, secure views, semantic view, triggered task
│   └── 05_ai_assist.sql             optional AI recommendations (evidence only)
├── tests/
│   ├── seed_golden_dataset.sql      synthetic labelled dataset (with near-twin false-merge traps)
│   └── RESULTS.md                   last run
├── stewardship_app/streamlit_app.py starter Streamlit-in-Snowflake command UI
└── run.py                           deploy + test runner
```

## Run it

Requirements: Python 3.10+, `snowflake-connector-python`, a role that can create tables, Dynamic Tables, Hybrid Tables, semantic views, streams, tasks and procedures in a schema, and a warehouse. Hybrid Tables require an AWS or Azure account (Preview on GCP); Cortex AI functions require the chosen model to be available in your region (or cross-region inference).

```bash
pip install snowflake-connector-python
cd implementation
python run.py all --connection <connection-name> --database <DB> --schema MDM_DEMO --warehouse <WH>
# options: deploy | test | all   --golden-n 2000   --ai-model claude-sonnet-4-6
```

`deploy` is re-runnable (`CREATE OR REPLACE`). `test` truncates the demo tables, runs the scenario suite, then the golden dataset, and writes `tests/RESULTS.md`.

## Using the command path

```sql
-- resolve whatever has landed
CALL SP_RESOLVE_ACCOUNTS('v1');

-- steward merges a suspect match (idempotent on the first argument)
CALL SP_MDM_COMMAND('cmd-001', 'MERGE',
     PARSE_JSON('{"survivor_entity_id":"<A>","superseded_entity_id":"<B>","candidate_id":"<C>","comment":"confirmed"}'),
     'steward.one');

-- reverse it later, even after new source updates
CALL SP_MDM_COMMAND('cmd-002', 'UNMERGE', PARSE_JSON('{"merge_event_id":"<ledger event>"}'), 'steward.one');

-- other commands: NO_MATCH {candidate_id}, OVERRIDE_ATTRIBUTE {entity_id, attribute_name, value, reason},
--                 ERASE {entity_id, legal_basis, approved_by}   (approved_by must differ from the actor)
```

## Results on synthetic data (N = 2,000 true entities, 3,514 records)

| Metric | Value | Reading |
|---|---|---|
| Auto-link precision | 1.000 (866 TP, 0 FP) | Zero false merges — deterministic rules only |
| Recall, automatic only | 0.611 | Duplicates without a shared tax ID are not auto-linked by design |
| Recall incl. steward routing | 1.000 | Every remaining true duplicate was routed to a steward case |
| Steward referral | 594 cases (16.9% of records) | 551 true duplicates + 43 near-twin traps correctly sent to review |
| Hybrid Table point lookup | ~50 ms median server execution | Client round-trip is dominated by network/driver; benchmark from the app tier |
| AI recommendation (10 cases) | 6/6 decided agree with truth; 4 UNSURE | Recommendations persisted; mastered state unchanged |

The synthetic data is designed to stress the guardrails, not to estimate your production rates. Replace it with a labelled sample of your own Informatica merges and known false merges.

## Production hardening checklist (not in the reference)

- Split layers into schemas (`MDM_RAW`, `MDM_CORE`, …) with RBAC per layer; masking/row-access policies and tags on PII columns.
- Incremental resolution at scale: blocking keys (postal / name prefix / `AI_EMBED` vector buckets) instead of full postal joins; Dynamic Table `REFRESH_MODE = INCREMENTAL` where the query qualifies.
- Re-evaluation of records linked to a survivor *after* a merge when that merge is undone (the reference keeps them on the survivor and relies on a steward review).
- Hierarchy (`ENTITY_RELATIONSHIP` with validity), consent attribute group, reference data tables.
- Master history table (SCD-2) or Time Travel-based as-of views for temporal analytics.
- Openflow Snowflake-to-Kafka connector on `OUT_ACCOUNT_EVENTS_PUBLISH_STREAM` (Preview) or a producer service.
- CI/CD with DCM Projects or dbt; the test runner as a pipeline gate; resource monitors and budgets.
- Address-verification integration (Marketplace provider or external access).
