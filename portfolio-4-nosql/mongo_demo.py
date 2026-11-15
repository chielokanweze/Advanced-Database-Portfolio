
from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path

from pymongo import MongoClient, ReadPreference, WriteConcern
from pymongo.errors import OperationFailure, WriteError
from pymongo.read_concern import ReadConcern

from gclib import MONGO_URI, Report, pg_connect

HERE = Path(__file__).resolve().parent
out = Report(HERE / "results" / "mongo_demo_output.txt")
client = MongoClient(MONGO_URI)
db = client.gracecare
patients = db.get_collection("patients", write_concern=WriteConcern(w="majority"))
DEMO_ID = "GC00000007"


def show(obj) -> None:
    out(json.dumps(obj, indent=2, default=str))


def explain_summary(cursor_explain: dict) -> dict:
    stats = cursor_explain["executionStats"]
    plan = cursor_explain["queryPlanner"]["winningPlan"]

    def stages(p):
        s = [p.get("stage")]
        for k in ("inputStage", "queryPlan"):
            if k in p:
                s += stages(p[k])
        for c in p.get("inputStages", []):
            s += stages(c)
        return s

    return {"plan stages": " <- ".join(x for x in stages(plan) if x),
            "documents examined": stats["totalDocsExamined"],
            "index keys examined": stats["totalKeysExamined"],
            "documents returned": stats["nReturned"],
            "time ms": stats["executionTimeMillis"]}


def m1() -> None:
    out.heading("M1  Open one patient's complete record")
    t = time.perf_counter()
    doc = patients.find_one({"_id": DEMO_ID})
    ms = (time.perf_counter() - t) * 1000
    out(f"MongoDB: db.patients.findOne({{_id: '{DEMO_ID}'}}) -> 1 document, {len(doc['visits'])} embedded visits, "
        f"{sum(len(v['labs']) for v in doc['visits'])} lab results, client round trip {ms:.1f} ms")
    out(f"summary sub-document: {doc['summary']}")
    pg = pg_connect()
    n = pg.execute("""SELECT (SELECT count(*) FROM appointments a JOIN patients p USING (patient_id) WHERE p.hospital_no = %s)
                           + (SELECT count(*) FROM diagnoses d JOIN appointments a USING (appointment_id) JOIN patients p USING (patient_id) WHERE p.hospital_no = %s)
                           + (SELECT count(*) FROM prescriptions x JOIN appointments a USING (appointment_id) JOIN patients p USING (patient_id) WHERE p.hospital_no = %s)
                           + (SELECT count(*) FROM lab_orders x JOIN appointments a USING (appointment_id) JOIN patients p USING (patient_id) WHERE p.hospital_no = %s)""",
                   (DEMO_ID,) * 4).fetchone()[0]
    pg.close()
    out(f"PostgreSQL: the same record is {n} rows spread over 4 tables (+ 5 lookup tables) and needs "
        "a 6-table join (Portfolio 2, Q1).")


def m2() -> None:
    out.heading("M2  Index design - critical lab results not yet reviewed")
    query = {"visits.labs": {"$elemMatch": {"flag": "CRITICAL", "status": "RESULTED"}}}
    out("query: db.patients.find(" + json.dumps(query) + ")")
    patients.drop_indexes()
    before = explain_summary(patients.find(query).explain())
    out("before (no secondary index):")
    show(before)
    patients.create_index([("visits.labs.flag", 1), ("visits.labs.status", 1)], name="idx_lab_flag_status")
    patients.create_index([("name.last", 1), ("name.first", 1)], name="idx_name")
    patients.create_index([("visits.start_at", 1)], name="idx_visit_date")
    after = explain_summary(patients.find(query).explain())
    out("after createIndex({'visits.labs.flag': 1, 'visits.labs.status': 1})  (a multikey index):")
    show(after)
    out(f"documents examined: {before['documents examined']} -> {after['documents examined']}")
    hits = list(patients.find(query, {"_id": 1, "name": 1}))
    out(f"patients with an unreviewed critical result: {[h['_id'] for h in hits]}")
    out("indexes now on the collection: " + ", ".join(i["name"] for i in patients.list_indexes()))


def m3() -> None:
    out.heading("M3  Aggregation pipeline - top 3 primary diagnoses per department, Jul-Sep 2026")
    pipeline = [
        {"$unwind": "$visits"},
        {"$match": {"visits.status": "COMPLETED",
                    "visits.start_at": {"$gte": datetime(2026, 7, 1, tzinfo=timezone.utc),
                                        "$lt": datetime(2026, 10, 1, tzinfo=timezone.utc)}}},
        {"$unwind": "$visits.diagnoses"},
        {"$match": {"visits.diagnoses.primary": True}},
        {"$group": {"_id": {"department": "$visits.department", "diagnosis": "$visits.diagnoses.description"},
                    "cases": {"$sum": 1}}},
        {"$sort": {"_id.department": 1, "cases": -1}},
        {"$group": {"_id": "$_id.department",
                    "top": {"$push": {"diagnosis": "$_id.diagnosis", "cases": "$cases"}}}},
        {"$project": {"top": {"$slice": ["$top", 3]}}},
        {"$sort": {"_id": 1}},
    ]
    out("pipeline stages: " + " -> ".join(next(iter(s)) for s in pipeline))
    for row in patients.aggregate(pipeline):
        out(f"  {row['_id']:<26} " + "; ".join(f"{t['diagnosis']} ({t['cases']})" for t in row["top"]))


def m4() -> None:
    out.heading("M4  Aggregation pipeline - malaria cases per month (B50.9 + B54)")
    pipeline = [
        {"$unwind": "$visits"},
        {"$unwind": "$visits.diagnoses"},
        {"$match": {"visits.diagnoses.code": {"$in": ["B50.9", "B54"]}, "visits.diagnoses.primary": True}},
        {"$group": {"_id": {"$dateToString": {"format": "%Y-%m", "date": "$visits.start_at", "timezone": "Africa/Lagos"}},
                    "cases": {"$sum": 1},
                    "children_under_16": {"$sum": {"$cond": [
                        {"$lt": [{"$dateDiff": {"startDate": "$date_of_birth", "endDate": "$visits.start_at",
                                                "unit": "year"}}, 16]}, 1, 0]}}}},
        {"$sort": {"_id": 1}},
    ]
    for row in patients.aggregate(pipeline):
        out(f"  {row['_id']}  cases {row['cases']:4}  of which children {row['children_under_16']:4}  "
            + "#" * (row["cases"] // 5))


def m5() -> None:
    out.heading("M5  Flexible schema - polymorphic lab results")
    out("Only positive malaria films have a 'species' field; other results do not. No schema change needed.")
    pipeline = [
        {"$unwind": "$visits"}, {"$unwind": "$visits.labs"},
        {"$group": {"_id": {"test": "$visits.labs.test", "has_species": {"$ne": [{"$type": "$visits.labs.species"}, "missing"]}},
                    "results": {"$sum": 1}}},
        {"$sort": {"_id.test": 1, "_id.has_species": 1}},
    ]
    for row in patients.aggregate(pipeline):
        out(f"  test {row['_id']['test']:<6} species field present = {str(row['_id']['has_species']):<5} results {row['results']}")
    example = next(patients.aggregate([
        {"$match": {"visits.labs.species": "P. falciparum"}}, {"$unwind": "$visits"}, {"$unwind": "$visits.labs"},
        {"$match": {"visits.labs.species": "P. falciparum"}}, {"$replaceRoot": {"newRoot": "$visits.labs"}},
        {"$limit": 1}]), None)
    if example:
        out("example element: " + json.dumps(example, default=str))


def m6() -> None:
    out.heading("M6  Atomic single-document update - book a new visit")
    before = patients.find_one({"_id": DEMO_ID}, {"summary.visit_count": 1})["summary"]["visit_count"]
    new_visit = {"appointment_id": 9_000_001, "start_at": datetime(2026, 12, 2, 9, 0, tzinfo=timezone.utc),
                 "status": "BOOKED", "reason": "Follow-up visit", "department": "General Outpatient",
                 "doctor": {"doctor_id": 6, "name": "Dr Demo"}, "diagnoses": [], "prescriptions": [], "labs": []}
    res = patients.update_one({"_id": DEMO_ID},
                              {"$push": {"visits": new_visit}, "$inc": {"summary.visit_count": 1}})
    after = patients.find_one({"_id": DEMO_ID}, {"summary.visit_count": 1})["summary"]["visit_count"]
    out(f"update_one($push visit, $inc summary.visit_count): matched={res.matched_count} modified={res.modified_count}")
    out(f"visit_count {before} -> {after}. Both changes are in ONE document, so MongoDB applies them atomically "
        "without a transaction.")
    patients.update_one({"_id": DEMO_ID}, {"$pull": {"visits": {"appointment_id": 9_000_001}},
                                           "$inc": {"summary.visit_count": -1}})
    out("(demo visit removed again)")


def m7() -> None:
    out.heading("M7  Schema validation - the database rejects malformed documents")
    bad_docs = [
        ("sex 'X' and date_of_birth as a string",
         {"_id": "GC99999999", "name": {"first": "Bad", "last": "Record"}, "sex": "X", "date_of_birth": "1990-01-01",
          "registered_at": datetime.now(timezone.utc), "visits": [], "summary": {"visit_count": 0}}),
        ("visit without a doctor",
         {"_id": "GC99999998", "name": {"first": "Bad", "last": "Visit"}, "sex": "F",
          "date_of_birth": datetime(1990, 1, 1, tzinfo=timezone.utc), "registered_at": datetime.now(timezone.utc),
          "visits": [{"appointment_id": 1, "start_at": datetime.now(timezone.utc), "status": "BOOKED",
                      "department": "Surgery"}],
          "summary": {"visit_count": 1}}),
    ]
    for label, doc in bad_docs:
        try:
            patients.insert_one(doc)
            out(f"  FAIL - accepted: {label}")
            patients.delete_one({"_id": doc["_id"]})
        except WriteError as e:
            details = e.details.get("errInfo", {}).get("details", {})
            rules = [r.get("propertyName") for r in details.get("schemaRulesNotSatisfied", [{}])[0].get("propertiesNotSatisfied", [])]
            out(f"  PASS - rejected ({label}): code {e.code} {e.details.get('errmsg')}; failing properties: {rules}")


def m8() -> None:
    out.heading("M8  Multi-document ACID transaction - pharmacy dispenses an open prescription")
    out("Two documents in two collections must change together: drug_stock (minus quantity) and the\n"
        "prescription status inside the patient document. This needs a replica set and a transaction.")
    stock = db.get_collection("drug_stock", write_concern=WriteConcern(w="majority"))
    rx = next(patients.aggregate([
        {"$match": {"visits.prescriptions.status": "PRESCRIBED"}}, {"$limit": 1},
        {"$unwind": "$visits"}, {"$unwind": "$visits.prescriptions"},
        {"$match": {"visits.prescriptions.status": "PRESCRIBED"}},
        {"$project": {"drug": "$visits.prescriptions.drug", "qty": "$visits.prescriptions.quantity"}},
        {"$limit": 1}]))
    target, drug, qty = rx["_id"], rx["drug"], rx["qty"]
    out(f"open prescription: patient {target}, {drug} x{qty}")

    def dispense(session):
        s = stock.find_one({"_id": drug}, session=session)
        stock.update_one({"_id": drug}, {"$inc": {"stock_qty": -qty}}, session=session)
        patients.update_one({"_id": target},
                            {"$set": {"visits.$[].prescriptions.$[p].status": "DISPENSED"}},
                            array_filters=[{"p.status": "PRESCRIBED", "p.drug": drug}], session=session)
        if s["stock_qty"] - qty < 0:        # checked AFTER both writes, to prove the abort undoes them
            raise ValueError(f"insufficient stock: have {s['stock_qty']}, need {qty}")

    def is_open():
        return patients.count_documents({"_id": target, "visits.prescriptions": {
            "$elemMatch": {"drug": drug, "status": "PRESCRIBED"}}}) > 0

    for label, start_stock in (("stock too low", qty - 1), ("stock sufficient", qty + 100)):
        stock.update_one({"_id": drug}, {"$set": {"stock_qty": start_stock}})
        with client.start_session() as session:
            try:
                session.with_transaction(dispense, read_concern=ReadConcern("snapshot"),
                                         write_concern=WriteConcern(w="majority"),
                                         read_preference=ReadPreference.PRIMARY)
                outcome = "COMMITTED"
            except ValueError as e:
                outcome = f"ABORTED ({e})"
        left = stock.find_one({"_id": drug})["stock_qty"]
        out(f"  {label:<16}: start stock {start_stock:>4} -> {outcome}; stock after = {left}; "
            f"prescription still open = {is_open()}")
    out("In the aborted run both writes had already been made inside the transaction; abortTransaction\n"
        "undid both. In the committed run both became visible together (all-or-nothing across documents).")


def main() -> None:
    hello = client.admin.command("hello")
    out(f"MongoDB {client.server_info()['version']}, replica set {hello['setName']}, primary {hello['primary']}, "
        f"members {hello['hosts']}")
    out(f"collection gracecare.patients: {patients.estimated_document_count()} documents")
    for fn in (m1, m2, m3, m4, m5, m6, m7, m8):
        fn()
    out.save()


if __name__ == "__main__":
    main()
