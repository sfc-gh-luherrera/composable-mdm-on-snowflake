# Architecture diagrams

All diagrams are Mermaid and render natively on GitHub. Figure numbers are referenced from [BLUEPRINT.md](BLUEPRINT.md); objects in **bold mono** exist in the [reference implementation](../implementation).

---

## Figure 1 — Current-state Informatica MDM landscape

Java handlers are the least-documented component and usually carry the hardest semantics.

```mermaid
flowchart LR
    subgraph SRC[Source systems]
        CRM[CRM]
        ERP[ERP]
        ECOM[E-commerce / other]
    end
    subgraph INFA[Informatica MDM]
        LAND[Landing / staging]
        CLEANSE[Cleanse + Address Verification]
        MM[Match & merge engine]
        BO[(ORS base objects<br/>XREF / history)]
        IDD[Data Director<br/>stewardship UI]
        JAVA[[Java user exits /<br/>event handlers]]:::risk
    end
    KAFKA{{Kafka}}
    DW[(Snowflake<br/>analytics copy)]
    BI[BI dashboards]
    APPS[Operational apps]

    CRM & ERP & ECOM --> KAFKA --> LAND --> CLEANSE --> MM --> BO
    IDD <--> BO
    BO --> JAVA
    JAVA -->|API calls| APPS
    JAVA -->|events| KAFKA
    BO -->|batch export| DW --> BI
    classDef risk fill:#ffe3e3,stroke:#d9480f,stroke-width:2px
```

---

## Figure 2 — Target composable MDM on Snowflake

Snowflake = system of mastering · Kafka = system of movement · apps = systems of record · agents = governed consumers.

```mermaid
flowchart LR
    subgraph SRC[Systems of record]
        CRM[CRM]
        ERP[ERP]
        OTH[Other sources]
    end
    K_IN{{Kafka<br/>mdm.domain.v1}}
    subgraph SF[Snowflake — system of mastering]
        direction LR
        OF_IN[Openflow Kafka connector<br/>Snowpipe Streaming HP]
        RAW[(RAW<br/>immutable events)]
        PREP[[PREP<br/>Dynamic Table<br/>standardize]]
        subgraph ENGINE[Mastering engine]
            RES[Identity resolution<br/>rules before AI]
            SURV[Survivorship<br/>versioned policy]
            CMD[Command path<br/>MERGE / UNMERGE / OVERRIDE / ERASE]
        end
        CORE[(CORE<br/>ENTITY · XREF · DECISIONS)]
        GOV[(GOV<br/>rules · ledger · cases · erasure)]
        GOLD[(GOLD<br/>golden + provenance)]
        SERVE[(SERVE<br/>Hybrid Table lookup)]
        OUT[(OUT<br/>publish table + stream)]
        PUB[PUBLISH<br/>secure views · sharing]
        SV[Semantic view]
    end
    OF_OUT[Openflow<br/>Snowflake → Kafka]
    K_OUT{{Kafka<br/>mdm.account.merged.v1 …}}
    STEW[Stewardship UI<br/>Streamlit / ISV]:::human
    AGENT[Cortex Agents]:::consume
    BI[BI / data products]:::consume
    APP[Operational apps<br/>sync duplicate check]:::consume

    CRM & ERP & OTH --> K_IN --> OF_IN --> RAW --> PREP --> RES --> CORE
    CORE --> SURV --> GOLD
    RES -- ambiguous --> GOV
    STEW -- commands only --> CMD --> CORE
    CMD --> GOV
    GOV -- ledger --> OUT --> OF_OUT --> K_OUT --> CRM & ERP
    GOLD --> PUB --> BI
    GOLD --> SV --> AGENT
    GOLD --> SERVE --> APP
    classDef human fill:#fff3bf,stroke:#f08c00
    classDef consume fill:#d3f9d8,stroke:#2b8a3e
```

---

## Figure 3 — Decomposing a POST_MERGE Java handler

```mermaid
flowchart TB
    J[[Legacy Java POST_MERGE handler]]:::risk
    J --> A[Hierarchy update<br/>must commit with merge]
    J --> B[Audit row]
    J --> C[Notify CRM<br/>retryable]
    J --> D[Publish ACCOUNT_UPDATED]
    J --> E[Legacy cache refresh]
    A --> A2[Snowflake mastering command<br/>same transaction as MERGE]
    B --> B2[GOV_MASTER_EVENT ledger]
    D --> D2[OUT publish table → Openflow → Kafka]
    C --> C2[Kafka consumer service<br/>owns retry + CRM API]
    E --> E2[RETIRE]
    classDef risk fill:#ffe3e3,stroke:#d9480f,stroke-width:2px
```

---

## Figure 4 — Transition states and authority progression

```mermaid
flowchart LR
    S1["State 1<br/>Consumption plane<br/><i>Informatica authoritative</i><br/>Wave 0 · M1–M2"]
    S2["State 2<br/>Shadow mastering<br/><i>Informatica authoritative</i><br/>daily reconciliation<br/>Wave 1 · M2–M4"]
    S3["State 3<br/>Analytical authority<br/><i>Snowflake for BI + AI</i><br/>Gate 2 · M5"]
    S4["State 4<br/>Operational authority<br/><i>Snowflake for apps</i><br/>Data Director retired<br/>Wave 4 · M6–M9"]
    R(["Renewal · MR<br/>commercial gate"])
    BR["Bridge 3–6 months<br/>decided Gate 3 · M6"]:::warn
    S1 --> S2 --> S3 --> S4 --> R
    S3 -. not ready .-> BR -.-> R
    classDef warn fill:#fff3bf,stroke:#f08c00
```

```mermaid
gantt
    title Waves and gates (R = 10, months relative to mobilisation)
    dateFormat  YYYY-MM
    axisFormat  M%m
    section Waves
    Wave 0 Foundation            :w0, 2000-01, 2M
    Wave 1 First domain          :w1, 2000-02, 4M
    Wave 2 B2B domains           :w2, 2000-04, 4M
    Wave 3 PII domains           :w3, 2000-05, 4M
    Wave 4 Operational authority :w4, 2000-06, 4M
    Wave 5 Retirement            :w5, 2000-09, 3M
    section Gates
    Gate 1 build-buy + outbound  :milestone, 2000-02-28, 0d
    Gate 2 analytical authority  :milestone, 2000-05-15, 0d
    Gate 3 bridge decision       :milestone, 2000-06-15, 0d
    Gate 4 decommission          :milestone, 2000-09-25, 0d
    Renewal MR                   :milestone, 2000-10-01, 0d
```
*(The Gantt uses a placeholder year; read the axis as programme months M1…M12.)*

---

## Figure 5 — Master record state machine

```mermaid
stateDiagram-v2
    [*] --> NEW
    NEW --> STANDARDIZED
    STANDARDIZED --> RESOLVED
    STANDARDIZED --> QUARANTINED: DQ failure
    RESOLVED --> REVIEW_REQUIRED: ambiguous
    REVIEW_REQUIRED --> RESOLVED: steward decision
    RESOLVED --> MASTERED
    MASTERED --> PUBLISHED
    PUBLISHED --> SUPERSEDED: MERGE (loser)
    SUPERSEDED --> REINSTATED: UNMERGE
    REINSTATED --> PUBLISHED
    PUBLISHED --> INACTIVE: source DELETE
    PUBLISHED --> TOMBSTONED: ERASE (identity kept, payload gone)
```

---

## Figure 6 — Stewardship command path and unmerge

```mermaid
sequenceDiagram
    autonumber
    actor S as Steward
    participant UI as Stewardship UI
    participant CMD as SP_MDM_COMMAND
    participant CORE as CORE (ENTITY / XREF)
    participant L as GOV_MASTER_EVENT
    participant OUT as OUT publish + stream
    participant K as Kafka
    S->>UI: Merge A ← B (reason)
    UI->>CMD: MERGE {survivor A, superseded B} command_id=c1
    CMD->>CMD: idempotency check (GOV_COMMAND_LOG)
    CMD->>CORE: re-point B's XREF to A, B = SUPERSEDED, versions +1
    CMD->>L: MASTER_MERGED {moved_record_hashes}
    CMD->>OUT: mdm.account.merged.v1
    OUT-->>K: Openflow CDC
    Note over CORE: later — new source updates arrive on B's records
    S->>UI: Unmerge (false merge found)
    UI->>CMD: UNMERGE {merge_event_id}
    CMD->>L: read moved_record_hashes
    CMD->>CORE: re-point only moved records to B, B = ACTIVE, suppression A↔B records
    Note over CORE: survivorship recomputes both masters from current source values
    CMD->>L: 2 × MASTER_UNMERGED
    CMD->>OUT: mdm.account.unmerged.v1 ×2
```

---

## Figure 7 — AI and agent architecture (AI recommends, policy decides)

```mermaid
flowchart LR
    U[Business user / steward] --> AG[Cortex Agent]
    AG -->|structured| SV[Semantic view<br/>SV_ACCOUNT_MDM]
    AG -->|unstructured| CS[Cortex Search<br/>glossary · policies · runbooks]
    AG -->|tools| T1[explain_match / inspect_provenance]
    AG -->|tool| T2[create_stewardship_case]
    SV --> GOLD[(GOLD + provenance)]
    subgraph ASSIST[AI assist — evidence only]
        SIM[AI_SIMILARITY<br/>blocking signal]
        LLM[AI_COMPLETE<br/>structured recommendation]
        REC[(GOV_AI_RECOMMENDATION<br/>model · prompt version · inputs hash)]
        SIM --> REC
        LLM --> REC
    end
    REC --> STEW[Steward decides]:::human
    STEW --> CMD[Command path]
    T2 --> CASES[(Stewardship cases)]
    X[["✗ No agent path to MERGE / UNMERGE / ERASE"]]:::risk
    classDef human fill:#fff3bf,stroke:#f08c00
    classDef risk fill:#ffe3e3,stroke:#d9480f
```

---

## Figure 8 — CoCo-assisted migration factory

```mermaid
flowchart LR
    A[Legacy artifacts<br/>ORS DDL · match rules · IDD config<br/>mappings · Java · samples] --> C((Cortex Code))
    C --> SPEC[Behavioral specs<br/>capability records]
    SPEC --> H1{Human approval<br/>semantics + owners}
    H1 --> C2((Cortex Code))
    C2 --> CODE[Target SQL / dbt /<br/>Snowpark / procedures]
    C2 --> TEST[Golden dataset +<br/>regression tests]
    C2 --> DOCS[Runbooks · ADRs ·<br/>evidence packs]
    CODE & TEST --> PR[Parallel run +<br/>reconciliation]
    PR --> H2{Go / no-go<br/>per consumer}
```

---

## Figure 9 — Latency classes and where each is served

```mermaid
flowchart TB
    EV[Source event] --> PIPE[Mastering pipeline<br/>Dynamic Tables · Streams · Triggered tasks<br/><b>minutes-scale</b>]
    PIPE --> PUB[PUBLISH views / Dynamic Tables] --> AN[Analytical ≤ 1 h]
    PIPE --> SV[Semantic views] --> AI[AI / agentic ≤ 15 min]
    PIPE --> OUT[Publish table + stream] --> OF[Openflow → Kafka] --> RE[Operational reactive ≤ 2 min]
    OF --> LR[Low-risk operational ≤ 15 min]
    PIPE --> SERVE[Hybrid Table refresh] --> SY[Operational synchronous ≤ 1 s<br/>point lookups only]
```

---

## Figure 10 — Reference implementation objects

```mermaid
erDiagram
    RAW_ACCOUNT_EVENTS ||--o{ PREP_ACCOUNT_STD : "latest per record (DT)"
    PREP_ACCOUNT_STD ||--|| CORE_ENTITY_XREF : "source_system + record_id"
    CORE_ENTITY ||--o{ CORE_ENTITY_XREF : "stable master id"
    CORE_MATCH_DECISION ||--o{ CORE_ENTITY_XREF : "linked_by_decision"
    CORE_MATCH_CANDIDATE ||--o| GOV_STEWARDSHIP_CASE : "suspect match"
    CORE_ENTITY ||--o{ GOV_MASTER_EVENT : "ledger (hashes only)"
    GOV_MASTER_EVENT ||--|| OUT_ACCOUNT_EVENTS_PUBLISH : "one row per event"
    GOV_SURVIVORSHIP_RULE ||--o{ GOLD_ACCOUNT_PROVENANCE : "rule_version"
    GOV_ATTRIBUTE_OVERRIDE ||--o{ GOLD_ACCOUNT_PROVENANCE : "steward wins"
    GOLD_ACCOUNT_PROVENANCE }o--|| GOLD_ACCOUNT : "pivot"
    GOLD_ACCOUNT ||--o{ SERVE_ACCOUNT_LOOKUP : "Hybrid Table"
    CORE_ENTITY ||--o| GOV_ERASURE_REQUEST : "ERASE"
    GOV_COMMAND_LOG ||--o{ GOV_MASTER_EVENT : "command_id"
```
