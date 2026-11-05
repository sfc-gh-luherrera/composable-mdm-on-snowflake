# Cortex Code (CoCo) prompt patterns

Use with the legacy artifacts checked into `source/` of your migration repo. Always review output; CoCo drafts, humans decide semantics.

## 1. Inventory
> Analyze the Informatica MDM artifacts and Java event handlers. For each active asset, identify domain, business intent, trigger, dependencies, reads/writes, external side effects, transactional requirements, consumer latency expectation, target disposition and open assumptions. Do not invent semantics. Mark all inferences as ASSUMPTION. Output one capability record per asset using templates/capability-record.md.

## 2. Behavioral extraction
> Convert each match, survivorship, workflow and Java behavior into a technology-neutral capability specification with preconditions, strong identifiers, fallbacks, approval requirements, historical override behavior, erasure impact and unmerge expectations. Do not generate target code yet.

## 3. Java decomposition
> For each Java handler, classify each responsibility as mastering state, internal derived update, audit, external integration, asynchronous orchestration or obsolete behavior. Recommend CONVERT, REBUILD, EXTERNALIZE, RETAIN or RETIRE for each responsibility, assign a latency class, and generate acceptance tests. Use templates/java-event-assessment.md.

## 4. Target build
> Using the approved capability specs and the patterns in implementation/sql (stable XREF, versioned GOV_*_RULE tables, SP_MDM_COMMAND, PII-free GOV_MASTER_EVENT), generate the Snowflake objects for domain <X>. Add scenario tests in the style of implementation/run.py for every acceptance test in the specs.

## 5. Reconciliation
> Compare Informatica and Snowflake outputs for the selected domain. Classify every material difference as expected_design_change, source_data_timing, conversion_defect, matching_disagreement, survivorship_disagreement, hierarchy_disagreement or requires_business_decision. Produce evidence and do not label systems equivalent without passing approved thresholds.
