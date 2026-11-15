# MIT 8103 Advanced Database Systems: Individual Practical Portfolio

**Student:** CHIELOKA NWEZE · **Matric no:** 2026/A/MIT/0848 · **Session:** 2026/2027, First Semester · **Programme:** Master of Information Technology, MIVA Open University

## Selected case study: GraceCare Specialist Hospital, Port Harcourt (simulated)

|                             |                                                                                                                                                                                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Organisation / scenario** | GraceCare Specialist Hospital, a simulated 98-bed private specialist hospital in Port Harcourt, Rivers State, Nigeria                                                                                                                                                                                         |
| **Nature of the business**  | Outpatient clinics (7 departments), emergency care, pharmacy, laboratory and inpatient wards (6 wards incl. ICU and maternity)                                                                                                                                                                                |
| **Users of the database**   | Front-desk staff, doctors, pharmacists, laboratory scientists, ward managers, hospital management (de-identified reports), auditors                                                                                                                                                                           |
| **Major data stored**       | Patients (incl. genotype and blood group), departments, doctors, appointments, ICD-10 diagnoses, drugs and stock, prescriptions, lab tests and results, wards, beds, admissions, and the audit trail                                                                                                          |
| **Key operations**          | Register a patient · book an appointment with no double booking · record a diagnosis · prescribe and dispense (stock correct under concurrency) · order, result and review lab tests (critical-result alerts) · admit and discharge (bed allocation) · retrieve a full patient history · management reporting |

All data is **synthetic** and generated reproducibly: 60,000 patients and about 123,000 appointments from 17 Nov 2025 to 31 Dec 2026, "as of" 14 Nov 2026. No real patient data is used. The design follows the **Nigeria Data Protection Act (NDPA) 2023**: least-privilege roles, a de-identified reporting view, and an audit trail.

The **same case study runs through all five portfolios**: one relational design is optimised, stressed under concurrency, re-modelled in NoSQL, and then distributed.

## Repository structure

```
advanced-database-portfolio/
├── README.md                          <- this file
├── AI_USE_DECLARATION.md
├── docker-compose.yml                 <- PostgreSQL primary + replica, MongoDB 3-node replica set,
│                                         Redis, Citus coordinator + 2 workers, Python tools image
├── run_all.py                         <- rebuilds everything and regenerates all results
├── infra/                             <- replication / replica-set initialisation scripts
├── tools/                             <- Dockerfile + pinned Python libraries + shared helper
├── portfolio-1-database-design/       <- schema, security, seed, constraint tests, ER diagram, normalisation
├── portfolio-2-query-optimisation/    <- workload queries, indexes / MV, benchmark, execution plans
├── portfolio-3-transactions-concurrency/ <- procedures + 7 concurrency demos (A-G)
├── portfolio-4-nosql/                 <- MongoDB document model + ETL + demos, Redis key-value demos
└── portfolio-5-distributed-cloud/     <- Citus sharding, MongoDB failover, PostgreSQL replication/failover, cloud design
```

Each portfolio folder has its own `README.md` explaining **what was built, how it was tested and what the results show**, plus a `results/` folder with the raw evidence.

## Technology

| Component      | Version                                                            | Role                                                         |
| -------------- | ------------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL     | 16.4                                                               | System of record (Portfolios 1–3, 5)                         |
| MongoDB        | 7.0.14, 3-member replica set                                       | Document model, multi-document transactions, failover (4, 5) |
| Redis          | 7.4.1                                                              | Key-value: cache, priority queue, counters (4)               |
| Citus          | 12.1.6 (PostgreSQL 16)                                             | Distributed / sharded PostgreSQL (5)                         |
| Python         | 3.12 (in container); psycopg 3.2.3, pymongo 4.10.1, redis-py 5.2.1 | Benchmarks and demos                                         |
| Docker Desktop | Compose v2                                                         | Reproducible environment; every server runs in a container   |

## How to run it

Requirements: **Docker Desktop** (running) and **Python 3.10+**. No database installation and no Python packages are needed on the host.

```bash
python run_all.py --fresh
```

This deletes any old containers and data, starts the stack, and runs Portfolios 1–5 in order, rewriting every file in the `results/` folders. It takes about 10–15 minutes on a laptop. To run a single part (after Part 1 has run once):

```bash
python run_all.py 3
```

Useful ports on the host: PostgreSQL primary `localhost:15432`, replica `localhost:15433` (user `gc`, password `gc_local_only`, a throw-away lab password).

## Summary of the five portfolios

| #   | Portfolio                             | What was implemented                                                                                                                                                                                                                      | Headline evidence                                                                                                                        |
| --- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Database design and modelling**     | 14-table 3NF/BCNF schema. Exclusion constraints stop overlapping bookings and bed double-occupancy; triggers enforce clinical rules; audit trail; 5 least-privilege roles; reproducible clinically consistent data.                       | 20/20 constraint tests PASS; 5/5 consistency checks = 0                                                                                  |
| 2   | **Query processing and optimisation** | 6 real workload queries; B-tree, partial, trigram (GIN) indexes; materialised view; a non-sargable query rewritten; cost of indexes measured                                                                                              | Execution plans before and after; speed-ups from about 20x to several hundred x; index sizes and write overhead reported                 |
| 3   | **Transactions and concurrency**      | Atomic dispensing procedure, savepoints, lost update + 3 fixes, non-repeatable read, write skew (RR vs SERIALIZABLE), concurrent double booking, deadlock + prevention, `SKIP LOCKED` bed queue                                           | Millisecond timelines from real concurrent sessions; lock waits captured from `pg_stat_activity`                                         |
| 4   | **NoSQL and advanced data models**    | MongoDB patient document model with `$jsonSchema` validation, ETL from PostgreSQL, multikey indexes, aggregation pipelines, multi-document transaction; Redis cache-aside, triage queue, counters                                         | `explain()`: 10,000 documents examined becomes 1; invalid documents rejected; transaction abort undoes both writes                       |
| 5   | **Distributed and cloud**             | Citus sharding (router vs fan-out, co-location, 2PC); MongoDB replica-set automatic failover and loss of majority; PostgreSQL streaming replication, stale reads, sync vs async, failover by promotion; cloud and HA design for GraceCare | Measured election time (2.9 s), promotion time (about 2 s), stale-read window, sync-commit cost; CAP/PACELC mapped to observed behaviour |

## Honest limitations

- **Not deployed to a public cloud.** All servers run as containers on one laptop. Failover and replication behaviour is real, but network latency between "data centres" is not, so absolute replication delays are optimistic. The cloud architecture in Portfolio 5 is a design.
- **Timings are from one laptop running Docker Desktop.** They vary between runs; the speed-up ratios and access paths are what matter. Each timing is a median of repeated runs.
- **Synthetic data.** It is realistic in structure and volume, but it is generated, not real hospital data.

## References

1. PostgreSQL Global Development Group (2024) _PostgreSQL 16 Documentation_: chapters 13 (Concurrency Control), 11 (Indexes), 14 (Performance Tips), 27 (High Availability, Load Balancing, and Replication); `CREATE TABLE ... EXCLUDE`. https://www.postgresql.org/docs/16/
2. MongoDB Inc. (2024) _MongoDB 7.0 Manual_: Data Modeling, Schema Validation, Transactions, Replica Set Elections, Write Concern. https://www.mongodb.com/docs/v7.0/
3. Redis Ltd. (2024) _Redis documentation_: data types (strings, hashes, sorted sets), key eviction. https://redis.io/docs/
4. Citus Data / Microsoft (2024) _Citus 12 documentation_: distributed tables, reference tables, co-location. https://docs.citusdata.com/
5. Elmasri, R. and Navathe, S. B. (2016) _Fundamentals of Database Systems_, 7th edn. Pearson. (Normalisation, transactions, concurrency control)
6. Kleppmann, M. (2017) _Designing Data-Intensive Applications_. O'Reilly. (Replication, partitioning, consistency)
7. Ports, D. R. K. and Grittner, K. (2012) "Serializable Snapshot Isolation in PostgreSQL", _Proceedings of the VLDB Endowment_, 5(12), pp. 1850–1861.
8. Abadi, D. (2012) "Consistency Tradeoffs in Modern Distributed Database System Design: CAP is Only Part of the Story", _IEEE Computer_, 45(2), pp. 37–42.
9. Federal Republic of Nigeria (2023) _Nigeria Data Protection Act, 2023_.
10. World Health Organization (2019) _International Statistical Classification of Diseases and Related Health Problems, 10th Revision (ICD-10)_.

## AI use

AI assistance was used. See [`AI_USE_DECLARATION.md`](AI_USE_DECLARATION.md) for what it was used for and how the work was verified.
