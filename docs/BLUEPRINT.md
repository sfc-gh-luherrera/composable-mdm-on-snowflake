# From Informatica MDM to Composable MDM on Snowflake

**An event-driven mastering and migration blueprint**

> **Core thesis.** The goal is not to reproduce Informatica in Snowflake. It is to preserve the business capabilities that matter, remove the ones that do not, and build a mastering architecture designed for an event-driven and agentic world — before the Informatica licence renewal.

Scope: Informatica MDM (Hub, Data Director, match/merge, Java user exits and event handlers), Kafka, Snowflake, BI tools, Cortex Code (CoCo) and Cortex Agents.

Timing convention: this guide uses **waves** and **programme months** (`M1` = programme mobilisation, `MR` = Informatica renewal). The worked example assumes **R = 10** (roughly eight to nine months of delivery before renewal). Re-base every month to your own contract date.

Architecture diagrams for every section are in [ARCHITECTURE.md](ARCHITECTURE.md). A tested reference implementation of the mastering model is in [`/implementation`](../implementation).

---

## TL;DR

- **Modernize, do not re-platform.** Snowflake becomes the system of *mastering*, Kafka stays the system of *movement*, operational applications stay systems of *record*, agents are governed *consumers*.
- **Deadline-aware.** The renewal date bounds the plan; waves overlap by domain rather than running in sequence.
- **Authority moves in four states** — consumption plane → shadow mastering → analytical authority → operational authority — consumer by consumer, each after parallel run and evidence.
- **Non-negotiables:** identity resolution separate from survivorship; every merge traceable and reversible; no PII in the decision ledger; sub-second reads from a separate serving layer; AI recommends, humans and policy decide.
- **Contingency:** a three-to-six-month Informatica bridge is a planned option, priced around `M4` and decided at Gate 3 (`M6`). The renewal is a *commercial* gate, never a *technical acceptance* gate (ADR-017).

## Contents

1. Executive summary
2. Modernization thesis and design principles
3. Options: why composable, and why not the alternatives
4. Current-state Informatica landscape
5. Capability and behavioral inventory
6. Target composable MDM architecture
7. Mastering model
8. Event-driven architecture, Kafka and latency
9. Java event decomposition
10. Stewardship, governance and reversibility
11. AI and Cortex Agent architecture
12. Transition architecture and coexistence
13. CoCo-assisted migration factory
14. Domain migration waves
15. Parallel run and reconciliation
16. Consumer-by-consumer cutover
17. Security, privacy, governance and operations
18. Programme plan, team and RACI
19. Commercial model and consumption
20. Architecture decisions (ADRs) and open decisions register
21. Risks and mitigations
22. Proof of concept (first domain)
23. Exit criteria and roadmap
Appendices A–D

---

## 1. Executive summary

The recommended direction is an **MDM modernization**, not a direct Informatica MDM re-platform. Informatica bundles data integration, matching, survivorship, hierarchy management, stewardship, workflow, audit and operational integration. The target separates those responsibilities into explicit capabilities and moves mastering authority only when each capability has been rebuilt, tested and accepted.

> **Target operating model.** Snowflake becomes the system of mastering. Kafka remains the system of movement. Operational applications remain systems of record. Agents become governed consumers and tools, not autonomous owners of master-data policy.

> **Timeline constraint.** With the renewal at `MR`, the programme has roughly `R-1` months for foundation, one proving domain, scale-out and operational cutover. Waves therefore overlap, the two longest-lead decisions (stewardship build-vs-buy and the outbound event mechanism) are fixed at Gate 1 (`M2`), and a short bridge extension of Informatica is negotiated as a contingency by `M6` — not discovered in `MR-1`. No consumer moves to Snowflake authority because the calendar says so.

### Recommended migration posture

- Begin with Snowflake as the governed **consumption plane** for analytics and AI while Informatica remains authoritative.
- Build Snowflake **shadow mastering** for the first domain (typically Account / Organization) and compare behavior against Informatica.
- Promote Snowflake to **analytical** mastering authority first, then to **operational** authority only after stewardship, merge/unmerge, audit and event publication are proven.
- Classify every Informatica rule, workflow and Java event as **Convert, Rebuild, Redesign, Retain, Externalize or Retire**.
- Use **Cortex Code (CoCo)** as a migration-factory accelerator — reverse-engineer behavior, generate drafts, tests, reconciliations and documentation. It is not an automatic Informatica MDM converter.
- Use AI for discovery, candidate generation, explanation and steward assistance. Keep survivorship policy, destructive merges and legal-entity changes deterministic and/or approval-controlled.

### Primary success criterion

The migration succeeds when every material behavioral difference between Informatica and Snowflake is either **eliminated or explained, approved and documented**, and no approved consumer or operational process still depends on an Informatica capability at renewal. Exact replication of obsolete or accidental legacy behavior is not a goal.

## 2. Modernization thesis and design principles

Composable MDM separates identity, policy, workflow, distribution and consumption instead of forcing every concern through one hub. Snowflake holds source evidence, runs deterministic transformations, manages identity crosswalks and golden state, retains decision provenance, publishes governed data products and exposes mastered context to analytics and agents. Kafka remains the backbone for decoupled event movement and operational fan-out.

| Principle | Meaning |
|---|---|
| Capabilities over objects | Do not recreate Informatica ORS structures because they exist. Rebuild required business behavior. |
| Events over snapshots | Preserve source change events and mastering decisions as traceable, replayable evidence. |
| Identity resolution ≠ survivorship | First decide which records are the same entity; separately decide which attribute wins. |
| Rules before AI | Strong identifiers and explainable scoring first. AI assists ambiguous cases; it is never an opaque policy engine. |
| Human review for high-impact ambiguity | False merges contaminate contracts, consent, invoices or regulatory data. Escalate destructive uncertainty. |
| Every decision traceable and reversible | A merge without provenance and unmerge is a liability, not mastering. |
| Erasable by design | Separate identity evidence from the decision ledger from day one. |
| Operational integration stays decoupled | Do not rebuild an enterprise integration layer inside Snowflake procedures. |
| Latency is a requirement | Every consumer class has a stated freshness target, served from the right layer. |
| Cut over consumers progressively | Analytical consumers can move before the hardest operational edge cases are retired. |

## 3. Options: why composable, and why not the alternatives

| Option | What it is | Strengths | Trade-offs |
|---|---|---|---|
| **A. Keep Informatica MDM, extend to Snowflake** | Renew; use Informatica's MDM extension for Snowflake to publish golden records for analytics and GenAI. | Lowest delivery risk; Data Director and match engine unchanged; fast analytics win. | Keeps renewal cost and hidden Java estate; mastering stays opaque to Snowflake governance and AI; defers the modernization question. Remains the natural **bridge**. |
| **B. Commercial MDM ISV on Snowflake** | Replace with a packaged MDM that runs natively on, or reads/writes directly to, Snowflake. | Packaged stewardship UI, hierarchy editor, workflow; vendor support. | Reintroduces a hub and a licence; procurement + onboarding rarely fits a sub-year window; rules again live outside version control. Survives as the **stewardship buy** option (§10.3). |
| **C. Composable MDM on Snowflake (recommended)** | Mastering rebuilt as versioned SQL/dbt/Snowpark, governed commands and an event ledger; thin stewardship UI; Kafka for movement. | No MDM licence; policies as code, fully auditable; native to the analytics/AI platform. | The organization must own mastering as a product; stewardship UX built or bought; highest first-year effort — mitigated by the CoCo factory and domain waves. |

> **Position.** Option C is the target. Option A is the contractual contingency. Option B survives only as a scoped stewardship purchase if Gate 1 says so.

## 4. Current-state Informatica landscape

Describe what Informatica *actually does*, not what the product is assumed to do. In mature estates the database model reveals only part of the behavior; match rules, survivorship, steward overrides, custom workflows and Java handlers often hold the semantics that matter most. (See *Figure 1* in ARCHITECTURE.md.)

**Inventory checklist**

- Domain models: customer, account/organization, party, household, supplier, product, location, hierarchy and reference data.
- Authoritative sources by attribute and country/business unit.
- Cleanse and standardization rules, match keys, thresholds and exception behavior — including embedded **address verification** (Informatica Address Verification / AddressDoctor) and any external DQ services.
- Survivorship: source priority, recency, completeness, trust/decay, manual override, attribute-level policies.
- Steward queues, approvals, SLAs, role model, historical overrides and steward headcount/usage (sizes the stewardship decision).
- Cross-reference IDs, merge history, unmerge semantics, hierarchy management and versioning.
- Reference data and code lists managed inside Informatica and their owners.
- Consent and preference attributes and their downstream legal consumers.
- Downstream subscriptions, exports, APIs, reports and operational side effects — each with its *actual* freshness expectation.
- Java user exits and event handlers: trigger, reads, writes, external calls, retry, concurrency, transaction coupling and business intent.

> **Assessment warning.** The Java inventory often exposes more real complexity than the physical MDM schema. Treat it as a first-class deliverable, complete by the end of Wave 0; it is the input to the effort baseline.

## 5. Capability and behavioral inventory

Map every asset to a business capability and a target disposition — this stops teams confusing physical artifacts with required behavior.

| Disposition | Use when |
|---|---|
| CONVERT | A mechanical translation exists (deterministic cleansing, SQL-style transforms). |
| REBUILD | The capability is required but should be implemented natively. |
| REDESIGN | The behavior exists, but the business or architecture should work differently. |
| RETAIN | Keep temporarily during coexistence. |
| EXTERNALIZE | Move distributed application behavior to an external runtime, not Snowflake. |
| RETIRE | Obsolete, redundant or without an approved consumer. |

Use the capability record template in [`templates/capability-record.md`](../templates/capability-record.md). Extract **behavior before target design**: the target schema implements approved behavior, not mirrored source tables.

```text
CAP-ACCOUNT-017  Account identity resolution
Trigger:          New account created in CRM
Strong identifier: validated tax ID
Fallback:         normalized legal name + postal address
Auto-match:       exact validated tax ID
Steward review:   high name similarity without legal identifier
Override:         approved steward value remains authoritative
Unmerge:          restore previous golden state
Latency:          duplicate check at creation ≤ 1 s (served from low-latency layer)
Acceptance:       golden test set + false-merge tolerance
```

## 6. Target composable MDM architecture

The target separates ingestion, source evidence, standardization, candidate generation, mastering decisions, canonical identity, survivorship, golden publication, stewardship, low-latency serving and operational distribution. It is intentionally *not* "Kafka lands data and the BI tool reads a final table." (See *Figure 2*.)

| Capability | Snowflake target | Design principle |
|---|---|---|
| Ingestion | Openflow Connector for Kafka (Snowpipe Streaming high-performance) | Immutable landing with event metadata |
| Source-aligned layer | `MDM_RAW` | Never overwrite source evidence |
| Standardization | Dynamic Tables / dbt / SQL / Snowpark | Versioned, testable normalization |
| Address verification | Marketplace provider or external access, decided per country in Wave 0 | Replace AddressDoctor explicitly |
| Data quality | SQL/dbt tests, Data Metric Functions, exception tables | Persist failed rules and evidence |
| Reference data | `MDM_GOV` reference tables with owner, effective dates, version | Business-owned, not hard-coded |
| Identity resolution | Deterministic + fuzzy scoring; `AI_SIMILARITY`/embeddings as blocking evidence | Explainable, reviewable decisions |
| Survivorship | Versioned policy tables | Business-owned attribute policies |
| Hierarchy | `ENTITY_RELATIONSHIP` with valid_from/valid_to/version | Reproducible as-of any date |
| Consent / preferences | Attribute group with jurisdiction, purpose, source, timestamp | Latest explicit consent wins; provenance mandatory |
| Golden state | `MDM_GOLD` + master versions | Stable master ID; temporal history |
| Stewardship | Command UI (build vs buy at Gate 1) | Commands, never direct table updates |
| Low-latency serving | Hybrid Tables (optionally read via Interactive warehouses) / lightweight API | Sub-second reads from a serving layer |
| Distribution | Secure views / data products / sharing + Openflow Snowflake-to-Kafka | Stable contracts, not internal tables |
| AI access | Cortex Agents + semantic views + Cortex Search + governed tools | Read / explain / recommend |
| Deployment | DCM Projects or dbt + CI/CD | Declarative, versioned infrastructure |

## 7. Mastering model

### 7.1 Identity resolution
Do these source records represent the same real-world entity? It creates or links a **stable master ID**; it does not decide which values survive.

`SOURCE RECORD → CANDIDATES → MATCH DECISION → MASTER ID / XREF`

### 7.2 Survivorship
For each attribute of an already-resolved master: which approved source value wins, under which rule, for which period?

`MASTER ID + SOURCE VALUES → ATTRIBUTE POLICY → GOLDEN RECORD + PROVENANCE`

### 7.3 Core entities

| Object | Purpose |
|---|---|
| ENTITY | Stable canonical identity without source semantics |
| ENTITY_IDENTIFIER | Known identifiers (tax ID, DUNS, email, phone, source keys) |
| ENTITY_XREF | source_system + source_record_id → master |
| ENTITY_RELATIONSHIP | Parent/child, works-for, household, supplier/location — with validity and version |
| MATCH_CANDIDATE / MATCH_FEATURE | Candidate evidence and explainable signals |
| MATCH_DECISION | Method, rule/model version, confidence, approver, timestamp |
| GOLDEN_RECORD | Current approved canonical representation |
| ATTRIBUTE_PROVENANCE | Which source value and rule won for each attribute |
| MASTER_EVENT | Immutable decision ledger — references and hashes, **never PII** |
| STEWARDSHIP_CASE | Human review for ambiguity, conflict, high-impact actions |
| REFERENCE_VALUE | Governed code lists |
| ERASURE_REQUEST | Right-to-erasure cases with completion evidence |

### 7.4 State machine and versions
`NEW → STANDARDIZED → RESOLVED → MASTERED → PUBLISHED`, with branches `AMBIGUOUS → REVIEW_REQUIRED`, `MERGED → SUPERSEDED`, `UNMERGED → REINSTATED`, `DELETED → INACTIVE`, `ERASED → TOMBSTONED` (identity kept, payload gone). Versions carry `master_version, valid_from, valid_to, is_current, change_reason, caused_by_event_id, caused_by_decision_id`. (See *Figure 5*.)

### 7.5 Unmerge design
Unmerge is not a reverse UPDATE. It is a new command that reconstructs the pre-merge state **from the ledger**: the MERGE event references the surviving and superseded masters and the records moved; UNMERGE reinstates the superseded master, re-points only those records, recomputes survivorship for both from *current* source values, records a suppression so automation does not re-link them, and publishes two `MASTER_UNMERGED` events. Test it with a merge that has since received further source updates — the hard case. (Implemented and tested: `SP_MDM_COMMAND('UNMERGE')`, tests T12–T14.)

## 8. Event-driven architecture, Kafka and latency

Kafka remains the event backbone. Snowflake receives source-domain events, materializes mastered state and publishes authoritative master events back to Kafka when operational consumers must react. **Kafka is not the MDM.**

### 8.1 Latency targets by consumer class

| Consumer class | Example | Target freshness | Served from |
|---|---|---|---|
| Analytical | BI dashboards, finance reporting | ≤ 1 h (typically 15 min) | `MDM_PUBLISH` views / Dynamic Tables |
| AI / agentic | Agent answering "who is this customer?" | ≤ 15 min | Semantic views over `MDM_GOLD` |
| Low-risk operational | Marketing sync, export files | ≤ 15 min | Master events → Kafka, or data products |
| Operational reactive | CRM/ERP updated after a merge | ≤ 2 min end-to-end | `MASTER_EVENT` → publish table stream → Openflow → Kafka → consumer |
| Operational synchronous | Duplicate check when a user creates an account | ≤ 1 s (benchmark target) | Hybrid Table / API fed from `MDM_CORE` — never the mastering pipeline |

> **Design consequence.** The mastering pipeline (Streams + Tasks, Dynamic Tables) is a minutes-scale engine. Anything a user waits for on a screen is served from a separate read-optimised layer refreshed from mastered state. Confusing the two is the most common cause of a failed "real-time MDM" on any warehouse. (Reference test T21: ~50 ms median server-side Hybrid Table point lookup; client latency depends on network and driver.)

### 8.2 Inbound event contract
`event_id, event_timestamp, source_system, source_record_id, source_updated_at, operation (UPSERT/DELETE/MERGE/ERASE), schema_version, correlation_id, payload`.

### 8.3 Domain-oriented topics
Inbound `mdm.<domain>.v1` (account, contact, product, supplier, location, relationship). Outbound `mdm.account.created|linked|merged|unmerged|attribute_overridden|erased.v1`, `mdm.account.stewardship.requested.v1`.

> **Exactly-once delivery into Snowflake does not make mastering exactly-once.** Mastering commands require their own idempotency (command_id, replay-safe procedures). (Tested: T10.)

### 8.4 Outbound publication mechanism (ADR-013)

Snowflake does not act as a Kafka producer from SQL, so the "Snowflake → Kafka" arrow needs an owner.

| Mechanism | How | Assessment |
|---|---|---|
| **Openflow Connector for Snowflake to Kafka** (preferred) | Snowflake-managed Openflow consumes a Snowflake **stream** on a publish table and writes CDC records to a topic. | Managed, same tooling as inbound. Constraints (docs, Nov 2026): **Preview**; one stream per connector; messages sent without a schema; no schema evolution. Use one flat publish table per topic and carry `schema_version` in the payload. Confirm GA/support position at Gate 1. |
| Java/Kotlin producer service | Delivery-partner-owned service reads the stream/change tracking and produces with a registered Avro schema. | Full contract and registry control; one more runtime. Fallback where registry enforcement is strict. |
| Snowpark Container Services producer | Producer packaged as a container in Snowflake. | In-platform, but still a producer to build and run. |

### 8.5 Schema governance
Schema Registry remains the event contract authority where Kafka standards exist. Snowflake schema evolution is a landing concern, not a replacement for producer/consumer contracts.

## 9. Java event decomposition

The goal is not to eliminate Java; the unit of migration is **behavior**, not language. (See *Figure 3*.)

| Existing Java behavior | Target |
|---|---|
| Calculates or normalizes data | SQL / dbt / Snowpark / UDF |
| Changes authoritative MDM state | Mastering command + stored procedure / state transition |
| Reacts to new mastered state (internal) | Stream + triggered task |
| Calls external APIs or operational apps | Kafka + service consumer; tightly governed external access where bounded |
| Orchestrates complex async workflows | Retain / externalize to a workflow runtime |
| Obsolete side effect | Retire |

```text
JAVA-EVENT-037  POST_MERGE Account
Reads: Party, Party_XREF, Hierarchy   Writes: hierarchy, audit
Side effects: CRM API, Kafka ACCOUNT_UPDATED
Transactional: hierarchy update must commit with merge
Async: CRM notification may retry independently
Latency class: operational reactive (≤ 2 min)
Target: DECOMPOSE → mastering state: Snowflake | audit: ledger | integration: Openflow → Kafka → consumer
```

> **Guardrail.** Do not recreate a distributed application server inside Snowflake Java procedures.

## 10. Stewardship, governance and reversibility

Stewardship is a **controlled command path** into mastering. The UI never updates golden tables; it submits commands (`MATCH | NO_MATCH | MERGE | UNMERGE | OVERRIDE_ATTRIBUTE | ERASE`) that the engine validates, executes and records. (See *Figure 6*.)

**Required audit evidence:** source records and candidate master; match features and identifiers; rule version and thresholds; model and prompt version when AI-assisted; decision, confidence, method; human user and comment; resulting master version; correlation to inbound and outbound events.

> **Non-negotiable:** no destructive mastering decision without provenance and reversibility.

### 10.2 What stewards actually do today
Quantify before the build-vs-buy gate: number of stewards, cases per week by type, handling time, screens used, load-bearing workflow steps (approval chains, SLA escalation, bulk actions).

### 10.3 Build vs buy (ADR-014)

| Option | Fit | Timeline | Choose when |
|---|---|---|---|
| Build: Streamlit in Snowflake command UI | Suspect queue, side-by-side compare, merge/unmerge/override with reason, case history; native RBAC. | POC-ready in Wave 1; production by ~`M6` if scope is held. | Small-to-moderate steward population; queue-and-approve workflow. |
| Buy: stewardship ISV on Snowflake | Packaged UX, hierarchy editor, bulk ops — must submit commands, not own golden state. | Procurement must start by `M2` to be viable. | Large steward population, heavy hierarchy editing, high UX bar. |
| Retain Data Director during coexistence | Decisions replayed into Snowflake as commands. | States 1–2 only. | Bridge only. |

> **Recommendation.** Build the command UI for the POC regardless (it proves the command path). Run a short ISV evaluation in parallel during `M2`. If the answer is "buy", the built UI remains the steward-of-last-resort console. A starter app is in [`implementation/stewardship_app`](../implementation/stewardship_app).

## 11. AI and Cortex Agent architecture

AI makes the MDM easier to discover, explain and operate — it does not silently own policy. Pattern: **Cortex Agents** with semantic views for structured data, **Cortex Search** over approved documentation, and narrowly scoped tools. (See *Figure 7*.)

| Agent action | Policy |
|---|---|
| Explain a master record / retrieve provenance / find suspected duplicates | Autonomous |
| Recommend a match | Autonomous recommendation (persisted) |
| Create a stewardship case | Permitted governed tool |
| Change survivorship policy / merge / unmerge / change legal attributes | Approval required |
| Erase a data subject | Never via agent; governed ERASE with legal approval |

**AI matching role.** Deterministic identifiers first, then fuzzy/semantic candidates and explainable scoring. `AI_SIMILARITY` / `AI_EMBED` on normalized name + address are useful blocking signals for long-tail candidates — evidence, not decisions. Reserve `AI_COMPLETE` reasoning for genuinely ambiguous cases, with structured output, and persist model, prompt version, inputs hash and outcome. (Implemented as `SP_AI_RECOMMEND`; test G05 proves it cannot change mastered state.)

## 12. Transition architecture and coexistence

Three architectures exist: current, transition, target. The transition architecture is the **risk-control mechanism** that moves authority progressively; with a short window, states overlap by domain. (See *Figure 4*.)

| State | Authority | Snowflake role | Typical window |
|---|---|---|---|
| 1. Consumption plane | Informatica | Lands Informatica golden + source events; serves BI/AI | Wave 0 (`M1–M2`) |
| 2. Shadow mastering | Informatica | Runs full mastering in parallel; daily reconciliation | Wave 1 (`M2–M4`) per domain |
| 3. Analytical authority | Snowflake for analytics/AI | Publishes golden to BI and agents; Informatica still feeds operations | From Gate 2 (`M5`) |
| 4. Operational authority | Snowflake | Master events drive operational apps; Data Director retired | Wave 4 (`M6–M9`) |

Informatica is retired only when no approved consumer depends on the capability being removed, or an approved RETIRE disposition ends the dependency.

## 13. CoCo-assisted migration factory

CoCo is a governed migration-engineering accelerator: read legacy artifacts, extract behavior, propose implementations, generate tests and documentation, find divergences, iterate. It is also the main lever for keeping the delivery team small enough to coordinate. (See *Figure 8*; prompts in [`/prompts`](../prompts).)

| Stage | CoCo contribution | Accountable human decision |
|---|---|---|
| Discover | Inventory schemas, rules, mappings, workflows, Java | Confirm what is active and relevant |
| Specify | Extract behavior into neutral capability specs | Approve semantics and owners |
| Design | Draft target model and patterns | Architecture review |
| Build | Generate SQL/dbt/Snowpark/procedures/tests/docs | Code review and engineering acceptance |
| Validate | Generate reconciliations, datasets, regression tests | Business/MDM acceptance |
| Cutover | Evidence packs, runbooks, rollback artifacts | Formal go/no-go |

**CoCo must not decide:** match thresholds and acceptable false-merge risk; source authority and survivorship ownership; whether historical behavior is correct or should retire; whether a destructive merge proceeds without approval; final cutover acceptance.

## 14. Domain migration waves

Migrate domain by domain. Because of the renewal window, Wave 2 starts when Wave 1 enters parallel run, not after it exits. (See *Figure 9*.)

| Wave | Scope | Objective | Window (R = 10) |
|---|---|---|---|
| Wave 0 | Platform foundation | Kafka contracts, Openflow in/out, RBAC, ledger, CI/CD, test framework, factory, inventory, Gate 1 decisions | `M1–M2` |
| Wave 1 | First domain (e.g. Account): POC → shadow → analytical authority | Prove identity, survivorship, stewardship, unmerge, Java decomposition, outbound event, reconciliation | `M2–M5` |
| Wave 2 | Supplier and remaining B2B domains | Scale patterns; relationships and hierarchies | `M4–M7` |
| Wave 3 | Customer/contact/PII-heavy domains | Erasure, consent, jurisdiction controls | `M5–M8` |
| Wave 4 | Operational write-back | Operational authority by consumer/process; retire Data Director | `M6–M9` |
| Wave 5 | Retirement and hardening | Decommission evidence; post-renewal stabilisation | `M9–M11` |

Per-domain lifecycle: `DISCOVER → SPECIFY → DESIGN → BUILD → VALIDATE → PARALLEL RUN → CUTOVER`.

## 15. Parallel run and reconciliation

Compilation success and row-count equality are not acceptance. Test at volume, attribute and behavioral levels with a golden dataset that over-represents known failure modes.

| Level | Examples |
|---|---|
| Volume | Inbound records, XREFs, masters, merges, unresolved suspects |
| Attribute | Legal name, tax ID, country, address, status, hierarchy, consent |
| Behavioral | Match/non-match, survivorship, overrides, merge/unmerge, late events, erasure |
| Operational | Latency per class, event publication, retry, side effects |
| Governance | Provenance, rule version, approval, RBAC, audit completeness |

**Golden dataset metrics:** precision, recall, **false-merge rate** (highest-risk error), false-split rate, steward referral rate (sizes the UI), survivorship accuracy, hierarchy accuracy as-of date, address validity vs current provider, traceability completeness. The reference implementation computes these on a synthetic dataset (tests G01–G03) — use the same harness with your own labelled sample.

## 16. Consumer-by-consumer cutover

Cut over consumers progressively instead of declaring one "MDM replacement" date: analytics → AI/search → low-risk downstream → synchronous checks (once the serving SLA is proven) → operational applications → retire the Informatica capability.

**Cutover evidence pack:** reconciliation results and approved differences; golden-dataset regression; access-control and masking validation; latency evidence against the consumer's class; lineage and audit; runbook and incident ownership; rollback status and recovery test.

**Minimum viable cutover for the renewal:** approved by the steering committee by `M5` — what must be on Snowflake authority by `MR-1`, what may remain on a *non-Informatica* retained path, and the triggers for exercising the bridge.

## 17. Security, privacy, governance and operations

### 17.1 Data governance
Attribute-level source authority and owner; version-controlled match and survivorship policies; PII classification, masking and least privilege (tags, masking/row-access policies); approved glossary and semantic views; retention semantics distinguishing source evidence from published state; audit retention for steward and AI-assisted decisions.

### 17.2 Right to erasure vs the immutable ledger (ADR-015)

| Layer | Contains | Erasure behavior |
|---|---|---|
| Source evidence (`MDM_RAW`/`PREP`) | Original payloads incl. PII | Deleted per retention policy; erasure removes the subject's rows. Time Travel and Fail-safe windows are part of the documented deletion latency. |
| Mastered state (`MDM_CORE`/`GOLD`) | Golden values, XREF, relationships | Master → TOMBSTONED: identity key kept, payload removed, hashed suppression retained |
| Decision ledger (`MASTER_EVENT`) | Metadata, rule/model versions, hashes, references — never raw PII | Immutable; nothing to erase. Unavoidable payload snapshots use per-subject keys destroyed on erasure (crypto-shredding). |

ERASE is a governed command with legal approval and a separate approver, an `ERASURE_REQUEST` record and an outbound `mdm.<domain>.erased.v1` event. A hashed suppression list survives erasure so late events do not re-master the subject (tested: T17–T19). Consent is a first-class attribute group; stale sources never overwrite an explicit withdrawal. Sector regulation (e.g. DORA, MiFID II record-keeping, health data rules) can lengthen legal-hold windows — the retention matrix records both.

### 17.3 Observability
Freshness per consumer class; DQ failures and verified-address rate; auto-match/suspect/false-positive rates; steward queue ageing and SLA breaches; inbound/outbound replay, duplicate, late and failed events; cost by mastering stage and Openflow runtime; rule versions and behavioral drift; erasure open/closed and time-to-erase.

## 18. Programme plan, team and RACI

### 18.1 Dated plan (relative months, R = 10)

| Milestone | Month | Gate / evidence |
|---|---|---|
| Programme mobilised; Wave 0 starts | `M1` | Team, environments, access, inventory tooling |
| Inventory complete (rules, Java, consumers, stewards) | mid-`M2` | Capability records with dispositions; effort baseline |
| **Gate 1** — stewardship build/buy; outbound mechanism; address provider | end `M2` | ADR-013/014 signed |
| First-domain POC complete | end `M3` | POC questions (§22) answered with evidence |
| Shadow mastering in parallel run | `M4` | Daily reconciliation |
| **Gate 2** — analytical authority; minimum viable cutover list | `M5` | Golden thresholds met; BI consumers moved |
| **Gate 3** — bridge decision | `M6` | Steering decides on bridge from Wave 2/3 status |
| Wave 2 domains at analytical authority | `M7` | Per-domain exit criteria |
| Wave 3 PII domains at analytical authority; erasure tested | `M8` | End-to-end erasure evidence |
| Operational consumers cut over; Data Director retired | `M8–M9` | Evidence pack per consumer |
| **Gate 4** — Informatica decommission go/no-go | late `M9` | No approved dependency remains |
| Informatica renewal | `M10` (`MR`) | Contract lapses or bridge exercised |
| Hardening and handover to run | `M10–M11` | Operational owner, support model, consumption baseline |

### 18.2 Team shape (planning assumption, finalised at Gate 1)

| Role | Org | Load |
|---|---|---|
| Programme lead / delivery manager | Delivery partner | 1 FTE |
| MDM solution architect | Delivery partner | 1 FTE |
| Snowflake data engineers (SQL/dbt/Snowpark) | Delivery partner | 3–4 FTE |
| Java / integration engineers | Delivery partner | 2 FTE |
| Stewardship UI engineer | Delivery partner | 1 FTE (0.5 if ISV) |
| Test / reconciliation engineer | Delivery partner | 1–2 FTE |
| MDM product owner | Organization | 1 FTE |
| Data stewards | Organization | As today, +20% during parallel run |
| DPO / legal | Organization | 0.2 FTE |
| Kafka platform owner | Organization | 0.3 FTE |
| Solutions engineer / architect | Snowflake | 0.3 FTE |
| Professional services (optional) | Snowflake | Bursts at Wave 0 and Gate 1 |

### 18.3 RACI

| Activity | Organization | Delivery partner | Snowflake |
|---|---|---|---|
| Business semantics, thresholds, dispositions | A/R | C | I |
| Inventory and behavioral specification | C | A/R | I |
| Target architecture and ADRs | A | R | C |
| Platform foundation (RBAC, Openflow, CI/CD) | C | R | C |
| Build: mastering engine, dbt, Snowpark, tests | I | A/R | C |
| Stewardship UI (build or ISV) | A | R | I |
| Java decomposition and Kafka consumers | C | A/R | I |
| Golden dataset and reconciliation | A | R | I |
| Erasure and retention design | A/R | R | C |
| Cutover go/no-go per consumer | A | R | I |
| Bridge negotiation with Informatica | A/R | C | I |
| Consumption sizing and cost governance | A | C | R |
| Run and support model | A | R (transition) | C |

> **Working principle.** The delivery partner delivers; the organization decides; Snowflake advises and unblocks. Every gate has a named organization approver.

If no delivery partner is involved, the organization's internal team takes the delivery-partner column.

## 19. Commercial model and consumption

**Goes away:** Informatica MDM licence and support at renewal (or bridge expiry); Informatica infrastructure and the Java application-server estate once decomposed; duplicate data movement out of the hub into analytics.

**Is added:** Snowflake compute for mastering, serving and publication; Openflow runtime; Cortex usage for agents and embeddings; optional stewardship ISV and address-verification subscriptions; delivery effort and a smaller run team.

| Stage | Dominant workload | Consumption pattern |
|---|---|---|
| State 1 | Landing + publication views | Low |
| State 2 | Mastering in parallel + reconciliation | Programme peak (~2× mastering + reconciliation) |
| State 3–4 | Incremental mastering, serving refresh, outbound events, agents | Steady; lower once reconciliation stops |

A sized estimate at Gate 1 needs four inventory inputs: daily source events per domain, records per domain, candidate fan-out, and refresh SLA per consumer class. Until then govern by design: resource monitors and budgets per stage, separate warehouses for mastering, reconciliation and serving, scheduled (not continuous) reconciliation.

**Bridge economics.** A three-to-six-month extension is cheaper than a failed cutover. Obtain the bridge price and notice period by `M4` so the `M6` decision is a choice, not a scramble.

## 20. Architecture decisions

| ADR | Statement |
|---|---|
| ADR-001 | Kafka remains the event backbone. |
| ADR-002 | Snowflake is the target system of mastering. |
| ADR-003 | Operational applications remain systems of record. |
| ADR-004 | No 1:1 replication of Informatica ORS. |
| ADR-005 | Java migration is behavior-based; external orchestration may remain Java. |
| ADR-006 | Identity resolution and survivorship are separate capabilities. |
| ADR-007 | Ambiguous high-impact merges require governed approval. |
| ADR-008 | Every merge supports traceable unmerge/reconstruction; master IDs are stable. |
| ADR-009 | Mastering policies are versioned and business-owned. |
| ADR-010 | CoCo accelerates engineering but does not determine business semantics. |
| ADR-011 | Parallel run and consumer-by-consumer cutover. |
| ADR-012 | Agents may explain/recommend; destructive master changes remain governed. |
| ADR-013 | Outbound master events via Openflow Snowflake-to-Kafka from one flat publish table per topic; Java producer fallback. Production use contingent on GA or an accepted support position (Preview as of Nov 2026). |
| ADR-014 | Stewardship is a command UI over the engine; build for POC; build-vs-buy at Gate 1; no UI edits golden tables. |
| ADR-015 | PII never enters the decision ledger; erasure is a governed command. |
| ADR-016 | Synchronous reads (≤ 1 s) served from a dedicated low-latency layer (Hybrid Tables: GA on AWS/Azure, Preview on GCP as of Nov 2026); benchmark in the POC at production-like concurrency. |
| ADR-017 | The renewal is a commercial gate, not a technical acceptance gate; the bridge is a planned contingency. |

### 20a. Open decisions register (template)

| Decision | Owner | Due | Status |
|---|---|---|---|
| ADR-014 stewardship build vs buy | MDM product owner | Gate 1 (`M2`) | Open |
| ADR-013 outbound mechanism | Architecture board | Gate 1 (`M2`) | Open |
| Address-verification provider per country | Data governance | Gate 1 (`M2`) | Open |
| Bridge price and notice period | Procurement / steering | `M4` | Open |
| Minimum viable cutover list | Steering committee | `M5` | Open |
| Bridge decision | Steering committee | Gate 3 (`M6`) | Open |

## 21. Risks and mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Renewal-driven deadline | Invites big-bang cutover under pressure | Overlapping waves; minimum viable cutover by `M5`; bridge priced by `M4`; Gate 3 at `M6` |
| Hidden Java behavior | Side effects absent from MDM config | First-class Java inventory, complete in Wave 0 |
| Stewardship adoption | A UI stewards refuse stalls operational authority | Usage inventory; stewards co-design in Wave 1; ISV evaluated in parallel |
| Incorrect matches | False merges contaminate legal, consent, financial data | Conservative thresholds, golden dataset, human review |
| Address quality regression | Losing AddressDoctor lowers precision and deliverability | Explicit provider at Gate 1; address-validity metric |
| Latency mismatch | Screens waiting on a minutes-scale pipeline | Consumer classes; serving layer; latency evidence per cutover |
| Lost semantics | Syntax preserved, behavior changed | Behavioral specs; parallel reconciliation |
| Irreversible state | Bad merges hard to recover | Versions, ledger, tested unmerge incl. post-merge updates |
| Erasure non-compliance | PII in an immutable ledger | ADR-015 separation; erasure tested in Wave 3 |
| Policy drift | Rules change without traceability | Versioned policy tables + CI/CD + owner approval |
| AI nondeterminism | Opaque recommendations become de facto policy | AI as evidence; governed decision boundary |
| Operational coupling | Snowflake becomes an integration hub | Kafka boundary; externalize side effects |
| Over-replication | Legacy complexity copied | Disposition review |
| Preview dependency | Outbound connector not GA at cutover | Java producer fallback ready; Gate 1 support position |
| Partner incentive conflict | Partner may also have an Informatica practice | Organization-owned gates; success tied to Informatica retirement |
| Compressed final peak | Waves 3–4 and Data Director retirement converge in `M8–M9` | Fix the minimum viable cutover list at `M5`; stagger consumers; pre-agree bridge scope |

## 22. Proof of concept (first domain)

Narrow but behaviorally representative; runs `M2–M3` and feeds Gates 1–2.

| Dimension | Suggested scope |
|---|---|
| Domain | Account / organization |
| Sources | Two representative systems (e.g. CRM + ERP) |
| Volume | ~100k records, or enough to cover long-tail cases |
| Rules | 10–20 representative cleanse/match/survivorship rules incl. one address rule |
| Java | 5–10 handlers across behavior classes |
| Stewardship | One suspect-match and one merge/unmerge workflow, exercised by two real stewards |
| Consumers | One BI view + one Cortex Agent use case + one synchronous duplicate check |
| Validation | Golden dataset + parallel reconciliation |
| Operational | One outbound master event through Openflow to Kafka, consumed by a service |
| Privacy | One end-to-end erasure on a test subject |

**Questions the POC must answer:** Can Snowflake reproduce or intentionally improve identity resolution? Can survivorship be explicit, versioned and explainable? Can Java events be decomposed without losing side effects? Can a published attribute be traced to source event, rule and steward decision? Does CoCo materially reduce effort? Can an incorrect merge be safely reversed after further updates? Do the outbound (≤ 2 min) and serving (≤ 1 s) targets hold? Will stewards accept the command UI? Can a subject be erased without breaking the ledger or re-mastering from late events?

The [`/implementation`](../implementation) folder is a working starting point that already answers several of these on synthetic data — see [IMPLEMENTATION.md](IMPLEMENTATION.md).

## 23. Exit criteria and roadmap

**Domain exit criteria:** all active capabilities have an approved disposition; material Java behavior classified and tested; golden-dataset thresholds met; material differences eliminated or approved; crosswalk integrity and lineage targets met; stewardship, merge, unmerge and erasure tested; latency evidence per consumer; acceptance and rollback documented; operational owner in place.

| Phase | Window (R = 10) | Outcome |
|---|---|---|
| Foundation | `M1–M2` | Platform controls, contracts, governance, factory; Gate 1 decisions |
| Pilot | `M2–M5` | First-domain shadow mastering with validated parity; analytical authority |
| Scale | `M4–M8` | Remaining domains via reusable patterns; erasure proven |
| Operational authority | `M6–M9` | Operational consumers on Snowflake master events; Data Director retired |
| Retirement | `M9–M11` | Informatica removed when no dependency remains, or bridge exercised |
| Run | `M10+` | Organization-owned mastering product; agent use cases expand |

> **Closing principle.** Do not use AI to translate the legacy MDM blindly. Use AI to reverse-engineer what it actually does, decide what should survive, rebuild it natively, prove the new system behaves correctly — and do it in an order that makes the renewal date a formality rather than a cliff.

---

## Appendix A. Target physical model

```text
MDM_RAW.<SOURCE>_<ENTITY>_EVENTS
MDM_PREP.<ENTITY>_STANDARDIZED              -- Dynamic Table
MDM_CORE.ENTITY | ENTITY_IDENTIFIER | ENTITY_XREF | ENTITY_RELATIONSHIP
MDM_CORE.<ENTITY>_MATCH_CANDIDATE | _MATCH_FEATURE | _MATCH_DECISION
MDM_GOLD.<ENTITY>_GOLDEN | <ENTITY>_HISTORY
MDM_GOV.ATTRIBUTE_PROVENANCE | MATCH_RULE | SURVIVORSHIP_RULE | REFERENCE_VALUE
MDM_GOV.STEWARDSHIP_CASE | ERASURE_REQUEST | MASTER_EVENT | COMMAND_LOG
MDM_SERVE.<ENTITY>_LOOKUP                    -- Hybrid Table
MDM_OUT.<ENTITY>_EVENTS_PUBLISH              -- one flat table per topic (Openflow stream source)
MDM_PUBLISH.V_<ENTITY>_360 | V_<ENTITY>_QUALITY | V_<ENTITY>_LINEAGE
MDM_PUBLISH.SV_<ENTITY>                      -- semantic view for agents
```
The reference implementation uses table-name prefixes (`RAW_`, `CORE_`, `GOV_`, …) so it fits in one schema.

## Appendix B. Suggested CoCo migration repository

```text
<org>-mdm-migration/
├── source/   ors-ddl/ clean-rules/ match-merge-rules/ survivorship-rules/ hierarchy-models/
│             workflows/ mappings/ java-events/ sample-data/
├── target/   ddl/ dbt/ snowflake-sql/ snowpark/ kafka-contracts/ openflow/ serving/
│             stewardship-ui/ semantic/ agents/ tests/
├── docs/     capability-inventory.md behavioral-specs/ target-architecture.md
│             migration-decisions.md retention-and-erasure.md acceptance-criteria.md
└── AGENTS.md
```

## Appendix C. CoCo prompt patterns
See [`/prompts`](../prompts): inventory, behavioral extraction, Java decomposition, reconciliation.

## Appendix D. Reference sources

| Reference | URL |
|---|---|
| Openflow Connector for Kafka (inbound, GA) | https://docs.snowflake.com/en/user-guide/data-integration/openflow/connectors/kafka/about |
| Openflow Connector for Snowflake to Kafka (outbound, Preview) | https://docs.snowflake.com/en/user-guide/data-integration/openflow/connectors/snowflake-to-kafka/about |
| Hybrid tables | https://docs.snowflake.com/en/user-guide/tables-hybrid |
| Interactive tables and warehouses | https://docs.snowflake.com/en/user-guide/interactive |
| Dynamic tables | https://docs.snowflake.com/en/user-guide/dynamic-tables-about |
| Triggered tasks | https://docs.snowflake.com/en/user-guide/tasks-triggered |
| DCM Projects | https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview |
| Semantic views | https://docs.snowflake.com/en/user-guide/views-semantic/overview |
| Cortex AI Functions (AI_COMPLETE, AI_SIMILARITY, AI_EMBED) | https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql |
| Cortex Agents | https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents |
| Cortex Code (CoCo) | https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code |
| External network access | https://docs.snowflake.com/en/developer-guide/external-network-access/external-network-access-overview |
| SnowConvert AI / Informatica PowerCenter migration | https://docs.snowflake.com/en/migrations/aim-for-datawarehouses/code-conversion/translation-references/informatica/README |
| Informatica MDM extension for Snowflake (Option A) | https://www.informatica.com/content/dam/informatica-com/en/collateral/solution-brief/unlock-analytics-and-empower-your-genai-applications-with-the-master-data-management-extension-for-snowflake_solution-brief_5190en.pdf |

*Feature status verified against Snowflake documentation in November 2026. Re-verify at Gate 1.*
