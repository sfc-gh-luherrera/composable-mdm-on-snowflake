"""
Stewardship command console (Streamlit in Snowflake starter).

The UI never writes to mastered tables. Every action calls SP_MDM_COMMAND, which
validates, executes, records the decision in the ledger and publishes the event.
Deploy: create a Streamlit app in the schema that holds the MDM objects.
"""
import json
import uuid

import streamlit as st
from snowflake.snowpark.context import get_active_session
from snowflake.snowpark.functions import col

session = get_active_session()
actor = session.sql("SELECT CURRENT_USER()").collect()[0][0]


def command(ctype: str, args: dict):
    res = session.call("SP_MDM_COMMAND", str(uuid.uuid4()), ctype, json.dumps(args), actor)
    res = json.loads(res) if isinstance(res, str) else res
    (st.success if res.get("status") == "OK" else st.error)(res)


st.title("MDM stewardship console")
q = session.table("PUB_MDM_QUALITY").to_pandas()
c = st.columns(4)
c[0].metric("Active masters", int(q.ACTIVE_MASTERS[0]))
c[1].metric("Open cases", int(q.OPEN_CASES[0]))
c[2].metric("Steward merges", int(q.STEWARD_MERGES[0]))
c[3].metric("Unmerges", int(q.UNMERGES[0]))

tab_queue, tab_history, tab_override = st.tabs(["Suspect queue", "Merge history", "Override"])

with tab_queue:
    cases = session.sql("""
        SELECT s.case_id, c.candidate_id, c.score, c.left_system, c.left_record_id,
               x.entity_id AS left_entity_id, c.right_entity_id,
               r.recommendation AS ai_recommendation, r.rationale AS ai_rationale
        FROM GOV_STEWARDSHIP_CASE s
        JOIN CORE_MATCH_CANDIDATE c ON c.candidate_id = s.candidate_id
        JOIN CORE_ENTITY_XREF x ON x.source_system = c.left_system AND x.source_record_id = c.left_record_id
        LEFT JOIN GOV_AI_RECOMMENDATION r ON r.case_id = s.case_id
        WHERE s.status = 'OPEN' ORDER BY c.score DESC LIMIT 200""").to_pandas()
    if cases.empty:
        st.info("No open cases.")
    else:
        pick = st.selectbox("Case", cases.CASE_ID, format_func=lambda cid: f"{cid[:8]}  score="
                            f"{cases.set_index('CASE_ID').loc[cid, 'SCORE']}")
        row = cases.set_index("CASE_ID").loc[pick]
        left = session.table("GOLD_ACCOUNT").filter(col("ENTITY_ID") == row.LEFT_ENTITY_ID).to_pandas()
        right = session.table("GOLD_ACCOUNT").filter(col("ENTITY_ID") == row.RIGHT_ENTITY_ID).to_pandas()
        a, b = st.columns(2)
        a.subheader("Left master"); a.dataframe(left.T)
        b.subheader("Right master"); b.dataframe(right.T)
        if row.AI_RECOMMENDATION:
            st.caption(f"AI recommendation (evidence only): {row.AI_RECOMMENDATION} — {row.AI_RATIONALE}")
        comment = st.text_input("Reason (required)")
        m1, m2 = st.columns(2)
        if m1.button("Merge (keep right as survivor)", disabled=not comment):
            command("MERGE", {"survivor_entity_id": row.RIGHT_ENTITY_ID, "superseded_entity_id": row.LEFT_ENTITY_ID,
                              "candidate_id": row.CANDIDATE_ID, "comment": comment})
        if m2.button("Not a match", disabled=not comment):
            command("NO_MATCH", {"candidate_id": row.CANDIDATE_ID, "comment": comment})

with tab_history:
    merges = session.sql("""
        SELECT m.master_event_id, m.entity_id AS survivor, m.related_entity_id AS superseded, m.created_at,
               d.actor, d.comment
        FROM GOV_MASTER_EVENT m JOIN CORE_MATCH_DECISION d ON d.decision_id = m.decision_id
        JOIN CORE_ENTITY e ON e.entity_id = m.related_entity_id AND e.status = 'SUPERSEDED'
        WHERE m.event_type = 'MASTER_MERGED' ORDER BY m.created_at DESC LIMIT 200""").to_pandas()
    st.dataframe(merges)
    if not merges.empty:
        evt = st.selectbox("Merge to reverse", merges.MASTER_EVENT_ID)
        reason = st.text_input("Unmerge reason")
        if st.button("Unmerge", disabled=not reason):
            command("UNMERGE", {"merge_event_id": evt, "comment": reason})

with tab_override:
    entity = st.text_input("Master entity_id")
    attr = st.selectbox("Attribute", ["legal_name", "tax_id", "email", "phone", "street", "postal_code", "country"])
    value = st.text_input("New value")
    reason = st.text_input("Justification")
    if entity:
        st.dataframe(session.table("GOLD_ACCOUNT_PROVENANCE").filter(col("ENTITY_ID") == entity.strip()).to_pandas())
    if st.button("Override", disabled=not (entity and reason)):
        command("OVERRIDE_ATTRIBUTE", {"entity_id": entity, "attribute_name": attr, "value": value, "reason": reason})
