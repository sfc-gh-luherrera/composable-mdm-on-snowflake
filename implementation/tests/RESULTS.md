# Test results

Run: 2026-11-05 15:51 — **29/29 passed** (account `SNOWHOUSE` AWS us-west-2, warehouse SNOWHOUSE, golden N=2000)

| ID | Check | Result | Detail |
|---|---|---|---|
| T01 | Resolution run summary | PASS | {'auto_links': 1, 'new_masters': 8, 'new_records': 9, 'rule_version': 'v1', 'run_id': '5afefe65-930a-4642-9a63-f1e2042c3588', 'stewardship_cases': 2} |
| T02 | Exact tax id auto-links across sources (normalized ES-A.. = ESA..) | PASS |  |
| T03 | Fuzzy name+postal never auto-merges: masters stay apart, case opened | PASS | open cases=2 |
| T04 | Conflicting tax ids block fuzzy candidates (false-merge guard) | PASS |  |
| T05 | Stable IDs: re-running resolution changes nothing | PASS |  |
| T06 | Survivorship: ERP wins legal_name by priority, most recent email wins | PASS | ('ACME INDUSTRIAL SA', 'billing@acme.example', 'ES') |
| T07 | Every golden attribute has provenance (rule version + source) | PASS | 5 |
| T08 | Decision ledger holds no PII or raw keys (hashes only) | PASS | 0 |
| T09 | Steward MERGE via command path | PASS | {'moved_records': 1, 'status': 'OK', 'superseded': '19c9d355-40b8-4208-8b01-9c0f33bbc3cd', 'survivor': 'd627a98d-e0e5-4325-b8ba-287c81845b90'} |
| T10 | Idempotent replay of the same command_id is not re-executed | PASS |  |
| T11 | Merge into a SUPERSEDED master is rejected | PASS | {'reason': 'both masters must be distinct and ACTIVE', 'status': 'REJECTED'} |
| T12 | UNMERGE after post-merge update: superseded master reinstated with current values | PASS | {'unmerge': {'records_restored': 1, 'reinstated': '19c9d355-40b8-4208-8b01-9c0f33bbc3cd', 'status': 'OK'}, 'e': [('new@northwind.example', None)], 'c': [(None, '+34600000001')]} |
| T13 | Suppression: resolution does not re-link unmerged records | PASS |  |
| T14 | Second UNMERGE of the same merge is rejected | PASS | {'reason': 'merge event not found or already reversed', 'status': 'REJECTED'} |
| T15 | NO_MATCH resolves the case and records a suppression | PASS |  |
| T16 | Steward override wins and is visible in provenance | PASS | [('Acme Industrial, S.A.', 'STEWARD_OVERRIDE')] |
| T17 | ERASE without an independent approver is rejected | PASS | {'reason': 'ACTIVE master, legal basis and a separate approver are required', 'status': 'REJECTED'} |
| T18 | ERASE: source evidence deleted, master tombstoned, ledger intact | PASS | {'erasure_request_id': 'c29bf4d7-0fcd-497b-9e32-20859aa336f6', 'source_records_erased': 1, 'status': 'OK'} |
| T19 | Late event for an erased subject is not re-mastered | PASS | {'auto_links': 0, 'new_masters': 0, 'new_records': 0, 'rule_version': 'v1', 'run_id': '87b0db23-becb-4d65-88d2-278a71d2594c', 'stewardship_cases': 0} |
| T20 | Every ledger event is published to its outbound topic table + stream | PASS | ['mdm.account.attribute_overridden.v1', 'mdm.account.created.v1', 'mdm.account.erased.v1', 'mdm.account.linked.v1', 'mdm.account.merged.v1', 'mdm.account.unmerged.v1'] |
| T21 | Hybrid Table duplicate-check lookup returns the master (client round-trip latency) | PASS | rows=12; server execution median=53.000ms max=103ms; client round-trip p50=434ms p95=946ms (incl. WAN + compile) |
| T22 | Semantic view answers an agent-style question (masters by country) | PASS | [(3, 'ES'), (2, 'DE'), (2, None)] |
| T23 | Event-driven tick (task body) consumes stream and resolves | PASS | {'auto_links': 0, 'new_masters': 0, 'new_records': 0, 'rule_version': 'v1', 'run_id': 'ab7bd158-52f0-4b8b-8462-76f8608a7038', 'stewardship_cases': 0} |
| G01 | False merge rate = 0 (auto-link precision 1.0) | PASS | precision=1.000 tp=866 fp=0 |
| G02 | Recall (auto) and recall incl. steward cases | PASS | auto=0.611 with_steward=1.000 fn=551 |
| G03 | Steward referral rate (cases / records) | PASS | cases=594 (16.9% of 3514 records); true duplicates routed to stewards=551; cases on non-duplicates=43 (steward workload, not merges) |
| G04 | Resolution throughput | PASS | 3514 records in 63.9s; {'auto_links': 866, 'new_masters': 2648, 'new_records': 3514, 'rule_version': 'v1', 'run_id': '57f99637-2d0b-4572-9b6b-dcd2fb95f8a6', 'stewardship_cases': 594} |
| G05 | AI assist writes recommendations only; mastered state unchanged | PASS | 10 recommendations (LIKELY_SAME=6, UNSURE=4); XREF row count and HASH_AGG identical before/after; model + prompt_version persisted |
| G06 | AI recommendation agreement with ground truth (informational) | PASS | agree=6/6 decided cases; 4 UNSURE left to stewards (claude-sonnet-4-6) |
