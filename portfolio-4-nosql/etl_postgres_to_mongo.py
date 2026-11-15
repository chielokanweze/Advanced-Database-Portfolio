
from __future__ import annotations

import json
import time
from collections import defaultdict
from datetime import datetime, time as dtime, timezone
from pathlib import Path

from bson import json_util
from pymongo import MongoClient, WriteConcern

from gclib import MONGO_URI, Report, pg_connect

HERE = Path(__file__).resolve().parent
MAX_PATIENT = 10_000
out = Report(HERE / "results" / "etl_output.txt")


def as_dt(d):
    """BSON has no pure 'date' type: store dates as midnight UTC datetimes."""
    return datetime.combine(d, dtime(0, 0), tzinfo=timezone.utc)


def fetch(conn, sql):
    cur = conn.execute(sql, (MAX_PATIENT,))
    cols = [c.name for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def main() -> None:
    t0 = time.perf_counter()
    pg = pg_connect()

    patients = fetch(pg, """SELECT patient_id, hospital_no, first_name, last_name, sex, date_of_birth,
                                   phone, blood_group, genotype, registered_at
                            FROM patients WHERE patient_id <= %s ORDER BY patient_id""")
    visits = fetch(pg, """SELECT a.appointment_id, a.patient_id, a.start_at, a.end_at, a.status, a.reason,
                                 dep.name AS department, d.doctor_id, 'Dr ' || d.first_name || ' ' || d.last_name AS doctor
                          FROM appointments a JOIN doctors d USING (doctor_id) JOIN departments dep USING (dept_id)
                          WHERE a.patient_id <= %s ORDER BY a.start_at""")
    diagnoses = fetch(pg, """SELECT dg.appointment_id, dg.icd10_code, c.description, dg.is_primary
                             FROM diagnoses dg JOIN icd10_codes c ON c.code = dg.icd10_code
                             JOIN appointments a USING (appointment_id)
                             WHERE a.patient_id <= %s ORDER BY dg.is_primary DESC""")
    prescriptions = fetch(pg, """SELECT p.appointment_id, dr.name AS drug, p.dosage, p.quantity, p.status, p.dispensed_at
                                 FROM prescriptions p JOIN drugs dr USING (drug_id)
                                 JOIN appointments a USING (appointment_id) WHERE a.patient_id <= %s""")
    labs = fetch(pg, """SELECT l.appointment_id, t.code, t.name, t.unit, l.result_value, l.result_flag,
                               l.status, l.resulted_at, l.reviewed_at
                        FROM lab_orders l JOIN lab_tests t USING (test_id)
                        JOIN appointments a USING (appointment_id) WHERE a.patient_id <= %s""")
    admissions = fetch(pg, """SELECT ad.patient_id, w.name AS ward, b.bed_label, ad.admitted_at, ad.discharged_at,
                                     ad.admission_reason
                              FROM admissions ad JOIN beds b USING (bed_id) JOIN wards w USING (ward_id)
                              WHERE ad.patient_id <= %s ORDER BY ad.admitted_at""")
    pg.close()
    out(f"read from PostgreSQL: {len(patients)} patients, {len(visits)} visits, {len(diagnoses)} diagnoses, "
        f"{len(prescriptions)} prescriptions, {len(labs)} lab results, {len(admissions)} admissions")

    # ---------------------------------------------------------------- group child rows
    dx_by_visit, rx_by_visit, lab_by_visit = defaultdict(list), defaultdict(list), defaultdict(list)
    for d in diagnoses:
        dx_by_visit[d["appointment_id"]].append(
            {"code": d["icd10_code"], "description": d["description"], "primary": d["is_primary"]})
    for p in prescriptions:
        rx_by_visit[p["appointment_id"]].append(
            {"drug": p["drug"], "dosage": p["dosage"], "quantity": p["quantity"], "status": p["status"],
             "dispensed_at": p["dispensed_at"]})
    for l in labs:
        result = {"test": l["code"], "name": l["name"], "value": float(l["result_value"]), "unit": l["unit"],
                  "flag": l["result_flag"], "status": l["status"], "resulted_at": l["resulted_at"]}
        if l["reviewed_at"]:
            result["reviewed_at"] = l["reviewed_at"]
        lab_by_visit[l["appointment_id"]].append(result)

    # Flexible schema in action: a positive malaria film carries an extra field that no other
    # test has. In SQL this would need a nullable column or a separate table.
    falciparum_visits = {d["appointment_id"] for d in diagnoses if d["icd10_code"] == "B50.9"}
    for appt_id, results in lab_by_visit.items():
        for r in results:
            if r["test"] == "MPD" and r["value"] > 0:
                r["species"] = "P. falciparum" if appt_id in falciparum_visits else "not speciated"

    visits_by_patient = defaultdict(list)
    for v in visits:
        visits_by_patient[v["patient_id"]].append({
            "appointment_id": v["appointment_id"],
            "start_at": v["start_at"],
            "status": v["status"],
            "reason": v["reason"],
            "department": v["department"],
            "doctor": {"doctor_id": v["doctor_id"], "name": v["doctor"]},
            "diagnoses": dx_by_visit.get(v["appointment_id"], []),
            "prescriptions": rx_by_visit.get(v["appointment_id"], []),
            "labs": lab_by_visit.get(v["appointment_id"], []),
        })
    adm_by_patient = defaultdict(list)
    for a in admissions:
        adm_by_patient[a["patient_id"]].append({
            "ward": a["ward"], "bed": a["bed_label"], "admitted_at": a["admitted_at"],
            "discharged_at": a["discharged_at"], "reason": a["admission_reason"]})

    # ---------------------------------------------------------------- build documents
    docs = []
    for p in patients:
        pv = visits_by_patient.get(p["patient_id"], [])
        attended = [v for v in pv if v["status"] == "COMPLETED"]
        conditions = sorted({d["code"] for v in attended for d in v["diagnoses"]})
        docs.append({
            "_id": p["hospital_no"],
            "name": {"first": p["first_name"], "last": p["last_name"]},
            "sex": p["sex"],
            "date_of_birth": as_dt(p["date_of_birth"]),
            "phone": p["phone"],
            "blood_group": p["blood_group"],
            "genotype": p["genotype"],
            "registered_at": p["registered_at"],
            "visits": pv,
            "admissions": adm_by_patient.get(p["patient_id"], []),
            "summary": {
                "visit_count": len(pv),
                "last_visit": max((v["start_at"] for v in attended), default=None),
                "conditions": conditions,
            },
        })

    # ---------------------------------------------------------------- load into MongoDB
    client = MongoClient(MONGO_URI)
    db = client.gracecare
    db.drop_collection("patients")
    validator = json.loads((HERE / "patient_validator.json").read_text(encoding="utf-8"))
    db.create_collection("patients", validator=validator, validationLevel="strict", validationAction="error")
    col = db.get_collection("patients", write_concern=WriteConcern(w="majority"))
    result = col.insert_many(docs, ordered=False)
    out(f"inserted {len(result.inserted_ids)} documents into gracecare.patients "
        f"(validator on, write concern w=majority)")

    # pharmacy stock collection for the multi-document transaction demo
    pg = pg_connect()
    stock = [{"_id": name, "stock_qty": qty} for name, qty in
             pg.execute("SELECT name, stock_qty FROM drugs ORDER BY name").fetchall()]
    pg.close()
    db.drop_collection("drug_stock")
    db.get_collection("drug_stock", write_concern=WriteConcern(w="majority")).insert_many(stock)
    out(f"inserted {len(stock)} documents into gracecare.drug_stock")

    stats = db.command("collStats", "patients")
    out(f"collection size: {stats['count']} documents, data {stats['size'] / 1024 / 1024:.1f} MB, "
        f"average document {stats['avgObjSize'] / 1024:.1f} KB")
    biggest = list(col.aggregate([{"$project": {"bytes": {"$bsonSize": "$$ROOT"}, "visits": {"$size": "$visits"}}},
                                  {"$sort": {"bytes": -1}}, {"$limit": 1}]))[0]
    out(f"largest document: {biggest['_id']} with {biggest['visits']} visits = {biggest['bytes'] / 1024:.1f} KB "
        f"({100 * biggest['bytes'] / (16 * 1024 * 1024):.3f}% of MongoDB's 16 MB document limit)")

    # a representative record: several visits, with prescriptions and lab results
    sample = col.find_one({"summary.visit_count": {"$gte": 3}, "visits.labs.0": {"$exists": True},
                           "visits.prescriptions.0": {"$exists": True}}, sort=[("_id", 1)])
    # MongoDB Extended JSON keeps the BSON types visible ({"$date": ...})
    (HERE / "sample_patient_document.json").write_text(
        json_util.dumps(sample, indent=2, json_options=json_util.RELAXED_JSON_OPTIONS), encoding="utf-8")
    out("sample document written to sample_patient_document.json")
    out(f"ETL finished in {time.perf_counter() - t0:.1f} s")
    out.save()


if __name__ == "__main__":
    main()
