# Portfolio 4: NoSQL and advanced data models

The same GraceCare data is modelled in two NoSQL stores, each chosen for a job the relational schema does less well:

| Store | Model | GraceCare use |
|---|---|---|
| **MongoDB 7** (3-member replica set) | Document | The patient record: one document holds a patient's whole history |
| **Redis 7** | Key-value (in-memory) | Patient banner cache, A&E triage queue, live ward-occupancy counters |

PostgreSQL remains the **system of record**. MongoDB is loaded from it by an ETL job, and Redis holds derived, short-lived data. This is *polyglot persistence*: each store does what it is best at.

## Files

| File | Purpose |
|---|---|
| `patient_validator.json` | `$jsonSchema` validator: required fields, types (dates are real BSON dates), enums and patterns, including nested visit fields |
| `etl_postgres_to_mongo.py` | Reads 10,000 patients plus all their visits, diagnoses, prescriptions, labs and admissions from PostgreSQL. Builds one document per patient and loads them with write concern `majority`. |
| `sample_patient_document.json` | One real document from the collection (MongoDB Extended JSON) |
| `mongo_demo.py` | M1–M8: queries, index design with `explain()`, aggregation pipelines, flexible schema, atomic update, validation, multi-document transaction |
| `redis_demo.py` | R1–R4: cache-aside with TTL, invalidation, priority queue (sorted set), atomic counters (hash) |
| `results/` | `etl_output.txt`, `mongo_demo_output.txt`, `redis_demo_output.txt` |

Run (after Part 1):

```bash
docker compose run --rm tools python portfolio-4-nosql/etl_postgres_to_mongo.py
docker compose run --rm tools python portfolio-4-nosql/mongo_demo.py
docker compose run --rm tools python portfolio-4-nosql/redis_demo.py
```

## Document model

```
patients (one document per patient, _id = hospital number)
├── name {first, last}, sex, date_of_birth (date), phone, blood_group, genotype, registered_at
├── visits [ ]                                  <- embedded: always read with the patient
│     ├── appointment_id, start_at (date), status, reason, department
│     ├── doctor {doctor_id, name}              <- extended reference: a copy of the fields needed for display
│     ├── diagnoses     [ {code, description, primary} ]
│     ├── prescriptions [ {drug, dosage, quantity, status, dispensed_at} ]
│     └── labs          [ {test, name, value, unit, flag, status, resulted_at, reviewed_at?, species?} ]
├── admissions [ {ward, bed, admitted_at, discharged_at, reason} ]
└── summary {visit_count, last_visit, conditions[]}   <- computed pattern: pre-aggregated on write
drug_stock (one document per drug)  <- used by the multi-document transaction demo
```

### Why embed?

The dominant access pattern is *"open this patient's record"*. That happens at every consultation and every pharmacy visit.

- In PostgreSQL it is a 6-table join (Part 2, Q1).
- In MongoDB it is **one** indexed read of **one** document (M1).

Embedding works here because the child data is:

- **owned** by the patient: a visit never belongs to two patients;
- **bounded**: at most 12 visits in 14 months, with the largest document 7 KB, about 0.04% of the 16 MB document limit;
- **read together** with the patient.

### Rules I followed (and where they would break)

| Rule | Applied here | Risk and mitigation |
|---|---|---|
| Embed what is read together and owned by the parent | visits, diagnoses, prescriptions, labs | A chronic patient over 20 years could grow large. Mitigation: the *subset pattern* (last 2 years embedded, older visits in a `visit_archive` collection) or the *bucket pattern* (one document per patient per year). |
| Reference what is shared and changes independently | Drug stock lives in its own collection, not inside patients | Stock changes with every dispensing in every patient record, so embedding it would be impossible to keep consistent |
| Copy (extended reference) only stable display fields | doctor name, department name inside each visit | If a doctor changes name, old visits keep the old name. That is acceptable, and arguably correct, for a historical record. |
| Validate even though the schema is "flexible" | `$jsonSchema` with `validationAction: "error"` | M7: a document with `sex: "X"` and a string date, and a visit without a doctor, are both rejected (code 121) |

## What the demos show

| Demo | Result (see `results/mongo_demo_output.txt`) |
|---|---|
| **M1** single read | 1 document with all visits and labs vs 12 rows across 4 tables plus lookups in SQL |
| **M2** index design | Critical-unreviewed-lab query: `COLLSCAN` examining **10,000** documents becomes `IXSCAN` examining **1** document with a compound **multikey** index on `visits.labs.flag + visits.labs.status` |
| **M3** aggregation | `$unwind -> $match -> $group -> $sort -> $group -> $slice`: top 3 diagnoses per department for Q3 2026 |
| **M4** aggregation | Monthly malaria cases with an under-16 breakdown (`$dateToString` in Africa/Lagos time, `$dateDiff` for age). Nov 2025 and Nov 2026 are partial months: the data starts 17 Nov 2025 and ends 14 Nov 2026. |
| **M5** flexible schema | Positive malaria films carry an extra `species` field that no other result has. No migration or nullable column is needed. |
| **M6** atomic single-document write | `$push` a visit and `$inc` the summary in one `update_one`: atomic without a transaction |
| **M7** validation | 2 malformed documents rejected with `DocumentValidationFailure` |
| **M8** multi-document ACID transaction | Dispensing changes `drug_stock` *and* the patient document. With too little stock the transaction aborts and **both** writes are undone; with enough stock both commit together. This requires the replica set. |

## Redis key-value design

| Key pattern | Type | Purpose | Result |
|---|---|---|---|
| `patient:{hospital_no}:banner` | string (JSON), TTL 300 s | **Cache-aside** for the patient banner shown on every screen | Cache hit about 8x faster than the PostgreSQL query in the recorded run (R1) |
| (same) | delete on write | **Invalidation**: without it a changed genotype stays wrong for up to 5 minutes (R2) | Shown: stale value, then correct value after `DEL` |
| `ae:triage:queue` | sorted set, score = category x 10^10 + arrival time | **A&E triage queue**: most urgent first, ties first-come-first-served; `ZADD` / `ZPOPMIN` are atomic and O(log n) | Category 1 (RTA) seen before the category 2s, which are seen before 3 and 4 (R3) |
| `ward:occupancy` | hash | **Live dashboard counters** with atomic `HINCRBY` | (R4) |

Redis is configured with `maxmemory 128mb` and `allkeys-lru`, so it can never run the server out of memory: the least recently used cache entries are evicted first. It runs with `appendonly yes`, but it is **not** the system of record. Everything in it can be rebuilt from PostgreSQL.

## Suitability: relational vs document vs key-value for GraceCare

| Requirement | PostgreSQL | MongoDB | Redis |
|---|---|---|---|
| Stock control, billing, booking rules (multi-row invariants, constraints) | **Best**: CHECK, EXCLUDE, FK, SERIALIZABLE | Possible with transactions, but there are no foreign keys and no exclusion constraints | No |
| Whole-patient read, variable lab formats, mobile/offline sync | Needs joins and schema changes | **Best** | No |
| Sub-millisecond reads, queues, counters, sessions | Possible but wasteful | No | **Best** |
| Ad-hoc analytics and reporting | **Best** (SQL, window functions, MVs) | Aggregation pipeline (good, but more verbose) | No |
| Horizontal scale-out | Citus / read replicas (Part 5) | Native sharding and replica sets | Redis Cluster |

**Other models considered (not implemented):**

- **Graph (Neo4j)** for infection contact-tracing, e.g. `(:Patient)-[:SHARED_WARD {from, to}]->(:Patient)`. Then "everyone within 2 contacts of a confirmed Lassa fever case" is one `MATCH` path query, where SQL would need recursive CTEs.
- **Column-family (Cassandra)** for high-volume bedside monitor readings: time-series keyed by `(patient_id, day)`.

Neither data set exists in the current GraceCare scope, so they were left as design notes.
