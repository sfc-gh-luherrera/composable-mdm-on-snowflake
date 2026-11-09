# Review: public reference implementation and latest Snowflake functionality

## 1. Reviewed repository

`github.com/zbrainiac-labs/MasterDataManagement` (cloned and reviewed November 2026; HEAD `05bac21`). It contains a batch pipeline on Dynamic Tables deployed with DCM (`bulk/`) and a near-real-time Python engine on Kafka + Postgres targeting SPCS (`nrt/`), plus a synthetic data generator and a regression suite.

**Licensing.** The repository has no LICENSE file, so its code is not redistributed here. It is the **base work** for this kit: this repo contains an independent re-implementation of its patterns, extended to close the gaps below. Credit: Marcel Däppen / zbrainiac-labs.

### What was tested

| Check | Method | Result |
|---|---|---|
| Master ID stability | Reproduced its `DENSE_RANK() OVER (ORDER BY cluster_id)` assignment on a 3-record set, then added one record whose cluster sorts first | **All existing master IDs changed** (1→2, 2→3). Downstream consumers holding IDs would silently point to different entities. |
| Cortex calls | Ran its `SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', …)` next to `AI_COMPLETE` and `AI_SIMILARITY` | Legacy call still works; `AI_COMPLETE` / `AI_SIMILARITY` are the current functions and support structured output. |
| Full deployment | Inspected `manifest.yml` | Requires a DCM project with its own database and three schemas (`MDM_RAW/AGG/SRV_v001`), a named warehouse and staged CSVs — not deployed into the shared test schema. |

### Reusable patterns vs gaps against the blueprint

| Reusable for a POC | Gap against the blueprint | Addressed in `/implementation` |
|---|---|---|
| Dynamic Table pipeline deployed with DCM; AI and classical variants side by side | Master IDs recomputed with `DENSE_RANK` each refresh; one-hop clustering — **not stable XREF** (ADR-008) | UUID assigned once in `CORE_ENTITY`; XREF re-pointed only by commands (T05) |
| Match signals: email, phone, canonical name, Jaro-Winkler, Soundex; 0.70 threshold | Rules hard-coded, not versioned or business-owned (ADR-009); batch and real-time rules differ | `GOV_MATCH_RULE` / `GOV_SURVIVORSHIP_RULE` with `rule_version` + `owner` |
| Survivorship: completeness > source priority > recency | No attribute-level provenance | `GOLD_ACCOUNT_PROVENANCE` (T07) |
| Kafka-in / Kafka-out with golden and XREF CDC events | No decision ledger with rule version or scores | `GOV_MASTER_EVENT` (hashes only, T08) + `CORE_MATCH_DECISION` |
| Cluster split with suppressions | Split is fix-forward, not ledger-based unmerge (§7.5) | Ledger-based UNMERGE incl. post-merge updates (T12–T14) |
| Streamlit golden-record and audit viewers | No steward command set or queue (§10) | `SP_MDM_COMMAND` + `stewardship_app` |
| Test-data generator (1.5K–1M records), regression and load tests | No erasure, consent or hierarchy model; LLM output can influence a merge (contradicts ADR-012) | ERASE with tombstone + suppression (T17–T19); AI writes only to `GOV_AI_RECOMMENDATION` (G05) |

## 2. Adapting to the latest Snowflake functionality (verified November 2026)

| Capability | Status (docs) | How the blueprint / implementation uses it |
|---|---|---|
| Openflow Connector for Kafka (inbound) | GA; Snowpipe Streaming high-performance architecture; JSON default, Avro/Protobuf configurable, DLQ | Inbound landing into `RAW_*_EVENTS` |
| Openflow Connector for Snowflake to Kafka (outbound) | **Preview**; one stream per connector; schemaless messages; no schema evolution | One flat `OUT_*_PUBLISH` table + append-only stream per topic; `schema_version` column; Java producer fallback kept in ADR-013 |
| Hybrid Tables | GA on AWS and Azure; **Preview on GCP** (since 30 Oct 2026) | `SERVE_ACCOUNT_LOOKUP` with enforced PK and secondary index |
| Interactive warehouses on standard / dynamic / hybrid tables | GA (zero-copy, Sep 2026) | Option for high-concurrency read APIs over published golden data without copying |
| Dynamic Tables | GA | `PREP_ACCOUNT_STD`; refresh triggered explicitly inside resolution for deterministic runs |
| Triggered tasks | GA | `TASK_RESOLVE_ACCOUNTS` runs when `RAW_ACCOUNT_EVENTS_STREAM` has data |
| DCM Projects | GA (Aug 2026) | Recommended deployment for the target; the SQL files are DCM-friendly |
| Semantic views | GA | `SV_ACCOUNT_MDM` for Cortex Agents / Analyst (Cortex Analyst usage is transitioning to Cortex Agents) |
| Cortex AI Functions (`AI_COMPLETE`, `AI_SIMILARITY`, `AI_EMBED`) | GA (model availability varies by region) | `SP_AI_RECOMMEND`: similarity signal + structured LLM recommendation, persisted with model and prompt version |
| Cortex Code (CoCo) | Available in Snowsight, desktop and CLI | Migration factory (§13) and the prompts in `/prompts` |

**Not changed by newer features:** the separation of the mastering pipeline (minutes) from synchronous serving (sub-second), the command path, the PII-free ledger, and the rule that AI output is evidence, not a decision.
