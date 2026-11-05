#!/usr/bin/env python3
"""
Deploy and test the composable MDM reference implementation.

    python run.py --connection <name> --database DB --schema SCHEMA --warehouse WH [deploy|test|all]

`test` runs a behavioral scenario suite (identity, survivorship, stewardship commands,
unmerge after post-merge updates, idempotency, erasure + late events, outbound events,
serving latency, semantic view) and a golden-dataset run with precision / recall /
false-merge metrics. Results are printed and written to tests/RESULTS.md.
"""
import argparse
import io
import json
import pathlib
import time
import uuid

import snowflake.connector

ROOT = pathlib.Path(__file__).parent
SQL_FILES = ["01_foundation.sql", "02_standardize_and_survive.sql",
             "03_mastering_engine.sql", "04_serve_publish_ai.sql", "05_ai_assist.sql"]


class MDM:
    def __init__(self, args):
        self.conn = snowflake.connector.connect(
            connection_name=args.connection, client_store_temporary_credential=True)
        self.wh = args.warehouse
        self.ai_model = args.ai_model
        self.q(f"USE WAREHOUSE {args.warehouse}")
        self.q(f"CREATE SCHEMA IF NOT EXISTS {args.database}.{args.schema}")
        self.q(f"USE SCHEMA {args.database}.{args.schema}")

    def q(self, sql, params=None):
        cur = self.conn.cursor()
        cur.execute(sql, params)
        try:
            return cur.fetchall()
        except Exception:
            return []

    def one(self, sql, params=None):
        rows = self.q(sql, params)
        return rows[0][0] if rows else None

    def run_file(self, path, **subs):
        text = path.read_text()
        for k, v in {"WAREHOUSE": self.wh, "AI_MODEL": self.ai_model, **subs}.items():
            text = text.replace("{{" + k + "}}", str(v))
        for _ in self.conn.execute_stream(io.StringIO(text), remove_comments=True):
            pass

    def call(self, sql, params=None):
        v = self.one(sql, params)
        return json.loads(v) if isinstance(v, str) else v

    def command(self, ctype, args, actor="steward.one", command_id=None):
        cid = command_id or str(uuid.uuid4())
        res = self.call("CALL SP_MDM_COMMAND(%s, %s, PARSE_JSON(%s), %s)",
                        (cid, ctype, json.dumps(args), actor))
        return cid, res

    def resolve(self):
        return self.call("CALL SP_RESOLVE_ACCOUNTS('v1')")

    def event(self, system, rid, payload, ts, op="UPSERT"):
        self.q("""INSERT INTO RAW_ACCOUNT_EVENTS (event_id, event_timestamp, source_system, source_record_id,
                   source_updated_at, operation, correlation_id, payload)
                  SELECT %s, %s::TIMESTAMP_NTZ, %s, %s, %s::TIMESTAMP_NTZ, %s, 'test', PARSE_JSON(%s)""",
               (str(uuid.uuid4()), ts, system, rid, ts, op, json.dumps(payload)))

    def entity_of(self, system, rid):
        return self.one("SELECT entity_id FROM CORE_ENTITY_XREF WHERE source_system=%s AND source_record_id=%s",
                        (system, rid))


# --------------------------------------------------------------------------- tests
class Suite:
    def __init__(self, m):
        self.m, self.results = m, []

    def check(self, tid, name, ok, detail=""):
        self.results.append((tid, name, bool(ok), str(detail)))
        print(f"  [{'PASS' if ok else 'FAIL'}] {tid} {name} {detail}")

    def scenarios(self):
        m = self.m
        print("Scenario suite")
        for t in ["RAW_ACCOUNT_EVENTS", "CORE_ENTITY", "CORE_ENTITY_XREF", "CORE_MATCH_CANDIDATE",
                  "CORE_MATCH_DECISION", "GOV_MASTER_EVENT", "GOV_STEWARDSHIP_CASE", "GOV_ATTRIBUTE_OVERRIDE",
                  "GOV_MATCH_SUPPRESSION", "GOV_ERASURE_SUPPRESSION", "GOV_ERASURE_REQUEST",
                  "GOV_COMMAND_LOG", "OUT_ACCOUNT_EVENTS_PUBLISH"]:
            m.q(f"TRUNCATE TABLE {t}")

        d = "2026-03-01 10:00:00"
        m.event("CRM", "C-001", {"legal_name": "Acme Industrial S.A.", "tax_id": "ES-A1234567", "postal_code": "28001",
                                 "country": "es", "email": "info@acme.example"}, d)
        m.event("ERP", "E-100", {"legal_name": "ACME INDUSTRIAL SA", "tax_id": "ESA1234567", "postal_code": "28001",
                                 "country": "ES", "email": "billing@acme.example"}, "2026-03-01 11:00:00")
        m.event("CRM", "C-002", {"legal_name": "Northwind Traders", "postal_code": "08001", "country": "ES",
                                 "phone": "+34 600 000 001"}, d)
        m.event("ERP", "E-200", {"legal_name": "Northwind Traders Ltd", "tax_id": "GB999", "postal_code": "08001",
                                 "country": "ES", "email": "old@northwind.example"}, d)
        m.event("CRM", "C-003", {"legal_name": "Contoso Pharma", "tax_id": "B99887766", "postal_code": "41001"}, d)
        m.event("ERP", "E-300", {"legal_name": "Contoso Pharma SL", "tax_id": "B11223344", "postal_code": "41001"}, d)
        m.event("CRM", "C-004", {"legal_name": "Jane Doe Consulting", "tax_id": "PT500", "postal_code": "1000",
                                 "email": "jane.doe@private.example"}, d)
        m.event("CRM", "C-007", {"legal_name": "Initech Systems", "postal_code": "10115", "country": "DE"}, d)
        m.event("ERP", "E-700", {"legal_name": "Initech Systems GmbH", "postal_code": "10115", "country": "DE"}, d)

        r = m.resolve()
        self.check("T01", "Resolution run summary", r["new_records"] == 9, r)
        self.check("T02", "Exact tax id auto-links across sources (normalized ES-A.. = ESA..)",
                   m.entity_of("CRM", "C-001") == m.entity_of("ERP", "E-100"))
        nw_c, nw_e = m.entity_of("CRM", "C-002"), m.entity_of("ERP", "E-200")
        cases = m.q("""SELECT c.candidate_id, c.left_record_id, c.right_entity_id FROM CORE_MATCH_CANDIDATE c
                       JOIN GOV_STEWARDSHIP_CASE s ON s.candidate_id = c.candidate_id WHERE s.status='OPEN'""")
        self.check("T03", "Fuzzy name+postal never auto-merges: masters stay apart, case opened",
                   nw_c != nw_e and len(cases) >= 2, f"open cases={len(cases)}")
        self.check("T04", "Conflicting tax ids block fuzzy candidates (false-merge guard)",
                   not any(c[1] in ("C-003", "E-300") for c in cases))
        self.check("T05", "Stable IDs: re-running resolution changes nothing",
                   m.resolve()["new_records"] == 0 and m.entity_of("CRM", "C-001") == m.entity_of("ERP", "E-100"))

        acme = m.entity_of("CRM", "C-001")
        g = m.q("SELECT legal_name, email, country FROM GOLD_ACCOUNT WHERE entity_id=%s", (acme,))[0]
        self.check("T06", "Survivorship: ERP wins legal_name by priority, most recent email wins",
                   g[0] == "ACME INDUSTRIAL SA" and g[1] == "billing@acme.example", g)
        prov = m.one("SELECT COUNT(*) FROM GOLD_ACCOUNT_PROVENANCE WHERE entity_id=%s AND rule_version='v1'", (acme,))
        self.check("T07", "Every golden attribute has provenance (rule version + source)", prov >= 5, prov)

        pii = m.one("""SELECT COUNT(*) FROM GOV_MASTER_EVENT m, RAW_ACCOUNT_EVENTS r
                       WHERE CONTAINS(m.detail::STRING, r.payload:legal_name::STRING)
                          OR CONTAINS(m.detail::STRING, COALESCE(r.payload:email::STRING, '§'))
                          OR CONTAINS(m.detail::STRING, r.source_record_id)""")
        self.check("T08", "Decision ledger holds no PII or raw keys (hashes only)", pii == 0, pii)

        # steward merge of Northwind, via its candidate
        cand = m.one("""SELECT candidate_id FROM CORE_MATCH_CANDIDATE
                        WHERE status='OPEN' AND ((left_record_id='E-200' AND right_entity_id=%s)
                                              OR (left_record_id='C-002' AND right_entity_id=%s))""", (nw_c, nw_e))
        cid, res = m.command("MERGE", {"survivor_entity_id": nw_c, "superseded_entity_id": nw_e,
                                       "candidate_id": cand, "comment": "same company, confirmed"})
        self.check("T09", "Steward MERGE via command path", res["status"] == "OK" and
                   m.entity_of("ERP", "E-200") == nw_c and
                   m.one("SELECT status FROM CORE_ENTITY WHERE entity_id=%s", (nw_e,)) == "SUPERSEDED", res)
        ledger_n = m.one("SELECT COUNT(*) FROM GOV_MASTER_EVENT")
        _, replay = m.command("MERGE", {"survivor_entity_id": nw_c, "superseded_entity_id": nw_e}, command_id=cid)
        self.check("T10", "Idempotent replay of the same command_id is not re-executed",
                   replay.get("replayed") is True and m.one("SELECT COUNT(*) FROM GOV_MASTER_EVENT") == ledger_n)
        _, rej = m.command("MERGE", {"survivor_entity_id": nw_c, "superseded_entity_id": nw_e})
        self.check("T11", "Merge into a SUPERSEDED master is rejected", rej["status"] == "REJECTED", rej)

        # hard case: post-merge source updates, then unmerge
        m.event("ERP", "E-200", {"legal_name": "Northwind Traders Ltd", "tax_id": "GB999", "postal_code": "08001",
                                 "country": "ES", "email": "new@northwind.example"}, "2026-04-01 09:00:00")
        m.resolve()
        email_merged = m.one("SELECT email FROM GOLD_ACCOUNT WHERE entity_id=%s", (nw_c,))
        merge_evt = m.one("SELECT master_event_id FROM GOV_MASTER_EVENT WHERE event_type='MASTER_MERGED' AND command_id=%s", (cid,))
        _, un = m.command("UNMERGE", {"merge_event_id": merge_evt, "comment": "false merge found by audit"})
        e_g = m.q("SELECT email, phone FROM GOLD_ACCOUNT WHERE entity_id=%s", (nw_e,))
        c_g = m.q("SELECT email, phone FROM GOLD_ACCOUNT WHERE entity_id=%s", (nw_c,))
        self.check("T12", "UNMERGE after post-merge update: superseded master reinstated with current values",
                   un["status"] == "OK" and email_merged == "new@northwind.example" and
                   m.entity_of("ERP", "E-200") == nw_e and e_g and e_g[0][0] == "new@northwind.example"
                   and c_g and c_g[0][0] is None and c_g[0][1] is not None, {"unmerge": un, "e": e_g, "c": c_g})
        m.resolve()
        self.check("T13", "Suppression: resolution does not re-link unmerged records",
                   m.entity_of("ERP", "E-200") != m.entity_of("CRM", "C-002"))
        _, un2 = m.command("UNMERGE", {"merge_event_id": merge_evt})
        self.check("T14", "Second UNMERGE of the same merge is rejected", un2["status"] == "REJECTED", un2)

        cand_i = m.one("""SELECT c.candidate_id FROM CORE_MATCH_CANDIDATE c WHERE c.status='OPEN'
                          AND c.left_record_id IN ('C-007','E-700')""")
        _, nm = m.command("NO_MATCH", {"candidate_id": cand_i, "comment": "different legal entities"})
        self.check("T15", "NO_MATCH resolves the case and records a suppression",
                   nm["status"] == "OK" and m.one("SELECT COUNT(*) FROM GOV_MATCH_SUPPRESSION WHERE reason='NO_MATCH'") == 1)

        _, ov = m.command("OVERRIDE_ATTRIBUTE", {"entity_id": acme, "attribute_name": "legal_name",
                                                 "value": "Acme Industrial, S.A.", "reason": "registry spelling"})
        won = m.q("SELECT attribute_value, won_by FROM GOLD_ACCOUNT_PROVENANCE WHERE entity_id=%s AND attribute_name='legal_name'", (acme,))
        self.check("T16", "Steward override wins and is visible in provenance",
                   ov["status"] == "OK" and won == [("Acme Industrial, S.A.", "STEWARD_OVERRIDE")], won)

        jane = m.entity_of("CRM", "C-004")
        _, e1 = m.command("ERASE", {"entity_id": jane, "legal_basis": "GDPR Art.17", "approved_by": "steward.one"})
        self.check("T17", "ERASE without an independent approver is rejected", e1["status"] == "REJECTED", e1)
        ledger_before = m.one("SELECT COUNT(*) FROM GOV_MASTER_EVENT WHERE entity_id=%s", (jane,))
        _, e2 = m.command("ERASE", {"entity_id": jane, "legal_basis": "GDPR Art.17", "approved_by": "dpo.one"})
        raw_left = m.one("SELECT COUNT(*) FROM RAW_ACCOUNT_EVENTS WHERE source_record_id='C-004'")
        self.check("T18", "ERASE: source evidence deleted, master tombstoned, ledger intact",
                   e2["status"] == "OK" and raw_left == 0 and
                   m.one("SELECT status FROM CORE_ENTITY WHERE entity_id=%s", (jane,)) == "TOMBSTONED" and
                   m.one("SELECT COUNT(*) FROM GOLD_ACCOUNT WHERE entity_id=%s", (jane,)) == 0 and
                   m.one("SELECT COUNT(*) FROM GOV_MASTER_EVENT WHERE entity_id=%s", (jane,)) == ledger_before + 1, e2)
        m.event("CRM", "C-004", {"legal_name": "Jane Doe Consulting", "tax_id": "PT500"}, "2026-05-01 00:00:00")
        late = m.resolve()
        self.check("T19", "Late event for an erased subject is not re-mastered",
                   late["new_records"] == 0 and m.entity_of("CRM", "C-004") is None, late)

        unpublished = m.one("""SELECT COUNT(*) FROM GOV_MASTER_EVENT m WHERE NOT EXISTS
                               (SELECT 1 FROM OUT_ACCOUNT_EVENTS_PUBLISH o WHERE o.master_event_id = m.master_event_id)""")
        topics = [r[0] for r in m.q("SELECT DISTINCT topic FROM OUT_ACCOUNT_EVENTS_PUBLISH ORDER BY 1")]
        stream_n = m.one("SELECT COUNT(*) FROM OUT_ACCOUNT_EVENTS_PUBLISH_STREAM")
        self.check("T20", "Every ledger event is published to its outbound topic table + stream",
                   unpublished == 0 and "mdm.account.merged.v1" in topics and "mdm.account.erased.v1" in topics
                   and stream_n > 0, topics)

        n_serve = m.one("CALL SP_REFRESH_SERVING()")
        lat = []
        for _ in range(20):
            t0 = time.perf_counter()
            hit = m.one("SELECT entity_id FROM SERVE_ACCOUNT_LOOKUP WHERE lookup_key = %s", ("TAX:ESA1234567",))
            lat.append((time.perf_counter() - t0) * 1000)
        lat.sort()
        srv = m.q("""SELECT MEDIAN(execution_time), MAX(execution_time)
                      FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 100))
                      WHERE query_text ILIKE 'SELECT entity_id FROM SERVE_ACCOUNT_LOOKUP%'""")[0]
        self.check("T21", "Hybrid Table duplicate-check lookup returns the master (client round-trip latency)",
                   hit == acme, f"rows={n_serve}; server execution median={srv[0]}ms max={srv[1]}ms; "
                   f"client round-trip p50={lat[10]:.0f}ms p95={lat[18]:.0f}ms (incl. WAN + compile)")

        sv = m.q("""SELECT * FROM SEMANTIC_VIEW(SV_ACCOUNT_MDM METRICS accounts.master_count DIMENSIONS accounts.country)""")
        self.check("T22", "Semantic view answers an agent-style question (masters by country)", len(sv) > 0, sv)

        tick = m.call("CALL SP_PIPELINE_TICK()")
        self.check("T23", "Event-driven tick (task body) consumes stream and resolves", "run_id" in tick, tick)

    def golden(self, n):
        m = self.m
        print(f"Golden dataset ({n} true entities)")
        for t in ["RAW_ACCOUNT_EVENTS", "CORE_ENTITY", "CORE_ENTITY_XREF", "CORE_MATCH_CANDIDATE",
                  "CORE_MATCH_DECISION", "GOV_MASTER_EVENT", "GOV_STEWARDSHIP_CASE", "GOV_MATCH_SUPPRESSION",
                  "GOV_ERASURE_SUPPRESSION", "OUT_ACCOUNT_EVENTS_PUBLISH"]:
            m.q(f"TRUNCATE TABLE {t}")
        m.run_file(ROOT / "tests" / "seed_golden_dataset.sql", N=n)
        t0 = time.time()
        r = m.resolve()
        elapsed = time.time() - t0
        met = m.q("""
            WITH rec AS (
                SELECT x.source_system, x.source_record_id, x.entity_id, r.payload:_truth_id::NUMBER AS truth
                FROM CORE_ENTITY_XREF x JOIN RAW_ACCOUNT_EVENTS r
                  ON r.source_system = x.source_system AND r.source_record_id = x.source_record_id),
            pairs AS (
                SELECT a.entity_id = b.entity_id AS predicted, a.truth = b.truth AS actual,
                       EXISTS (SELECT 1 FROM CORE_MATCH_CANDIDATE c
                               WHERE (c.left_system = a.source_system AND c.left_record_id = a.source_record_id
                                      AND c.right_entity_id = b.entity_id)
                                  OR (c.left_system = b.source_system AND c.left_record_id = b.source_record_id
                                      AND c.right_entity_id = a.entity_id)) AS has_case
                FROM rec a JOIN rec b ON a.source_system || a.source_record_id < b.source_system || b.source_record_id
                WHERE a.entity_id = b.entity_id OR a.truth = b.truth)
            SELECT
                COUNT_IF(predicted AND actual)                       AS tp,
                COUNT_IF(predicted AND NOT actual)                   AS fp,
                COUNT_IF(actual AND NOT predicted)                   AS fn,
                COUNT_IF(actual AND NOT predicted AND has_case)      AS fn_routed,
                (SELECT COUNT(*) FROM CORE_MATCH_CANDIDATE)          AS cases,
                (SELECT COUNT(*) FROM rec)                           AS records
            FROM pairs""")[0]
        tp, fp, fn, fn_routed, cases, recs = met
        precision = tp / (tp + fp) if tp + fp else 1.0
        recall_auto = tp / (tp + fn) if tp + fn else 1.0
        recall_with_steward = (tp + fn_routed) / (tp + fn) if tp + fn else 1.0
        self.check("G01", "False merge rate = 0 (auto-link precision 1.0)", fp == 0,
                   f"precision={precision:.3f} tp={tp} fp={fp}")
        self.check("G02", "Recall (auto) and recall incl. steward cases",
                   recall_with_steward >= 0.95,
                   f"auto={recall_auto:.3f} with_steward={recall_with_steward:.3f} fn={fn}")
        self.check("G03", "Steward referral rate (cases / records)", True,
                   f"cases={cases} ({cases / recs:.1%} of {recs} records); true duplicates routed to stewards={fn_routed}; "
                   f"cases on non-duplicates={cases - fn_routed} (steward workload, not merges)")
        self.check("G04", "Resolution throughput", True, f"{recs} records in {elapsed:.1f}s; {r}")

        before = m.q("SELECT COUNT(*), HASH_AGG(entity_id, source_system, source_record_id) FROM CORE_ENTITY_XREF")[0]
        n_ai = m.one("CALL SP_AI_RECOMMEND(10)")
        recos = m.q("""SELECT recommendation, COUNT(*) FROM GOV_AI_RECOMMENDATION GROUP BY 1 ORDER BY 1""")
        after = m.q("SELECT COUNT(*), HASH_AGG(entity_id, source_system, source_record_id) FROM CORE_ENTITY_XREF")[0]
        self.check("G05", "AI assist writes recommendations only; mastered state unchanged",
                   n_ai == 10 and before == after and
                   m.one("SELECT COUNT(*) FROM GOV_AI_RECOMMENDATION WHERE model IS NULL OR prompt_version IS NULL") == 0,
                   f"recommendations={recos}")
        agree = m.q("""
            SELECT COUNT_IF(ok), COUNT(*) FROM (
            SELECT (r.recommendation = 'LIKELY_SAME') = (rl.payload:_truth_id = rr.payload:_truth_id) AS ok
            FROM GOV_AI_RECOMMENDATION r
            JOIN GOV_STEWARDSHIP_CASE s ON s.case_id = r.case_id
            JOIN CORE_MATCH_CANDIDATE c ON c.candidate_id = s.candidate_id
            JOIN RAW_ACCOUNT_EVENTS rl ON rl.source_system = c.left_system AND rl.source_record_id = c.left_record_id
            JOIN CORE_ENTITY_XREF x ON x.entity_id = c.right_entity_id
            JOIN RAW_ACCOUNT_EVENTS rr ON rr.source_system = x.source_system AND rr.source_record_id = x.source_record_id
            WHERE r.recommendation <> 'UNSURE'
            QUALIFY ROW_NUMBER() OVER (PARTITION BY r.recommendation_id ORDER BY rr.source_record_id) = 1)""")
        self.check("G06", "AI recommendation agreement with ground truth (informational)", True,
                   f"agree={agree[0][0] if agree else 0}/{agree[0][1] if agree else 0}")

    def write(self):
        passed = sum(1 for r in self.results if r[2])
        lines = ["# Test results", "",
                 f"Run: {time.strftime('%Y-%m-%d %H:%M')} — **{passed}/{len(self.results)} passed**", "",
                 "| ID | Check | Result | Detail |", "|---|---|---|---|"]
        for tid, name, ok, det in self.results:
            lines.append(f"| {tid} | {name} | {'PASS' if ok else 'FAIL'} | {det.replace('|', '/')[:220]} |")
        (ROOT / "tests" / "RESULTS.md").write_text("\n".join(lines) + "\n")
        print(f"\n{passed}/{len(self.results)} passed")
        return passed == len(self.results)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", nargs="?", default="all", choices=["deploy", "test", "all"])
    p.add_argument("--connection", required=True)
    p.add_argument("--database", required=True)
    p.add_argument("--schema", default="MDM_DEMO")
    p.add_argument("--warehouse", required=True)
    p.add_argument("--golden-n", type=int, default=2000)
    p.add_argument("--ai-model", default="claude-sonnet-4-6")
    a = p.parse_args()
    m = MDM(a)
    if a.action in ("deploy", "all"):
        for f in SQL_FILES:
            print("deploy", f)
            m.run_file(ROOT / "sql" / f)
    if a.action in ("test", "all"):
        s = Suite(m)
        s.scenarios()
        s.golden(a.golden_n)
        raise SystemExit(0 if s.write() else 1)


if __name__ == "__main__":
    main()
