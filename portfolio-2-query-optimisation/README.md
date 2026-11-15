# Portfolio 2: Query processing and optimisation

Six queries that GraceCare staff really run were measured **before and after** optimisation on the Part 1 data set: 60,000 patients, about 123,000 appointments, about 106,000 diagnoses, about 104,000 prescriptions and about 73,000 lab results. Every claim below is backed by an `EXPLAIN (ANALYZE, BUFFERS)` plan in `results/plans/`.

## Files

| File | Purpose |
|---|---|
| `queries.sql` | The workload, one named block per query (`-- name: ...`) |
| `optimisations.sql` | Indexes and the materialised view, each with the query it serves and why |
| `drop_optimisations.sql` | Returns to the baseline (Part 1 schema only) |
| `run_benchmark.py` | Drops all optimisations, then plans and times every query (median of 9 runs after a warm-up). Creates the optimisations, repeats, and measures index sizes and write overhead. |
| `results/summary.md` | The before/after table (copied below) |
| `results/plans/` | Full `EXPLAIN (ANALYZE, BUFFERS)` output: `baseline__*.txt` and `optimised__*.txt` |
| `results/query_outputs.txt` | What each query actually returns |

Run (after Part 1): `docker compose run --rm tools python portfolio-2-query-optimisation/run_benchmark.py`

## The workload

| # | Who / when | Query |
|---|---|---|
| Q1 | Doctor opening a record | Full history of one patient: visits, primary diagnosis, prescriptions, lab results (6-table join plus 2 correlated subqueries) |
| Q2 | Clinic, every morning | One doctor's patient list for one day |
| Q3 | Patient-safety alert, polled every minute | CRITICAL lab results that no doctor has reviewed yet |
| Q4 | Front desk on the phone | Find a patient from a fragment of their phone number (`LIKE '%73591%'`) |
| Q5 | Management, monthly | Primary diagnoses per department per month for a quarter (join + aggregate over about 25,000 visits) |
| Q6 | Clinic dashboard | Number of visits on one day: written two ways |

## Results

Median of 9 runs; server-side execution time. Pages are 8 kB buffers touched in one run, a measure of work that does not depend on the hardware. The access paths for every row are in `results/summary.md`.

| Query | Baseline ms | Optimised ms | Speed-up | Pages before -> after | Key change in the plan |
|---|---:|---:|---:|---:|---|
| Q1 patient history | 50.4 | 0.28 | **180x** | 9,419 -> 124 | Seq Scan of `appointments` (123,369 rows) and **8 Seq Scans of `lab_orders`** (one per visit) -> index scans on `idx_appt_patient_start` and `idx_lab_orders_appointment` |
| Q2 doctor day list | 2.7 | 0.11 | **24x** | 1,580 -> 42 | Bitmap scan of the GiST exclusion-constraint index (every slot of doctor 12) -> Index Scan on `idx_appt_start` (one day only) |
| Q3 critical results not reviewed | 7.2 | 0.07 | **109x** | 1,006 -> 36 | Seq Scan removing 73,111 of 73,116 rows -> partial index holding only the 5 relevant rows |
| Q4 phone fragment search | 10.9 | 0.06 | **188x** | 732 -> 10 | Seq Scan -> Bitmap Index Scan on the trigram GIN index |
| Q5 monthly report, indexes only | 55.8 | 55.0 | 1.0x | 2,573 -> 1,462 | Index on `start_at` used, but the cost is in joining and aggregating about 25,000 rows |
| Q5 monthly report, **materialised view** | 55.8 | 0.11 | **516x** | 2,573 -> 8 | Reads the 150 pre-aggregated rows for the quarter |
| Q6 `WHERE start_at::date = ...` | 15.8 | 12.6 | 1.3x | 1,555 -> 118 | Even with the index it must scan *every* entry and filter out 122,921 rows |
| Q6 rewritten as a range | 12.6 | 0.04 | **331x** | 118 -> 3 | `Index Cond` on `start_at`: reads only that day's entries |

**Cost of the optimisations** (from `results/summary.md`):

| Item | Value |
|---|---|
| Index storage | 8.3 MB of new indexes on top of a 12 MB `appointments` heap. Largest: `idx_appt_patient_start` 3.8 MB, `idx_patients_phone_trgm` 2.0 MB. The partial index is only **16 kB**. |
| Write overhead | Bulk-inserting all 73,116 lab results with the two new `lab_orders` indexes took **about 2.9x as long** as with no indexes (38.5 ms vs 112.8 ms; UNLOGGED test table, median of 10 rounds) |

## Analysis

**Q1: a missing index on a foreign key multiplies with every visit.**

- PostgreSQL automatically indexes primary keys and UNIQUE constraints, but **not foreign keys**. `lab_orders.appointment_id` had no index, so the correlated lab subquery did a full Seq Scan of `lab_orders` for each of the patient's 8 visits (`loops=8` in the baseline plan).
- Diagnoses and prescriptions did *not* have this problem. Their UNIQUE constraints `(appointment_id, ...)` already create an index that starts with `appointment_id`. That is why the baseline plan shows index scans for them.
- Lesson: check every foreign key that is used for look-ups. The cost grows with the number of child lookups, so a patient with 50 visits would be far worse.

**Q2: the planner surprised me.**

- I expected a composite `(doctor_id, start_at)` index to win, and tested it first. The planner never used it: for a single day only about 450 rows match `start_at`, so the single-column `idx_appt_start` is cheaper. Following the evidence, I removed the composite index, since an unused index is pure cost.
- In the baseline the planner did *not* do a sequential scan. It used the GiST index that backs the `appt_no_doctor_overlap` exclusion constraint (`btree_gist` lets GiST answer `doctor_id = 12`). Constraints and indexes interact.

**Q3: partial indexes are ideal for "needle in a haystack" alerts.**

- Only 5 of 73,116 lab results are critical and unreviewed. A normal index on `result_flag` would store all 73,116 entries.
- The partial index (`WHERE result_flag = 'CRITICAL' AND status = 'RESULTED'`) stores only the rows the alert needs, already sorted by `resulted_at`, in 16 kB. When a doctor reviews a result, its status changes and the row leaves the index automatically.
- This query is polled every minute all day, so the 109x gain matters more here than anywhere else.

**Q4: B-trees cannot help a leading wildcard.**

- `LIKE '%73591%'` cannot use a B-tree, which is sorted from the first character.
- The `pg_trgm` GIN index breaks every phone number into 3-character pieces ("735", "359", "591"…) and intersects the lists for the search string. This is the same technique used for "contains" name searches.

**Q5: when indexes are not enough, pre-compute.**

- The report needs every visit in a quarter (about 25,000 rows), so most of the time goes on the hash joins and the aggregation, not on finding rows. The index on `start_at` barely changes the time (1.0x).
- The materialised view does the work once, so the report reads 150 ready-made rows (516x). The trade-off is staleness (see below).

**Q6: write predicates the index can use ("sargable").**

- `start_at::date = '2026-11-13'` wraps the column in a cast, so the planner cannot turn it into an index range. In the optimised run it used the smaller index as a cheaper "table" to scan end to end (118 pages instead of 1,555), but it still evaluated the cast for every one of 123,000 entries.
- Rewriting it as `start_at >= '2026-11-13' AND start_at < '2026-11-14'` gives a true range scan: 3 pages, 331x faster than the same query written the first way.
- On a `timestamptz` the cast to `date` depends on the session time zone, so it is not even *immutable*. It could not be given an expression index without `AT TIME ZONE 'Africa/Lagos'`. The range rewrite is the correct fix.

## How the optimiser works here (what I learned from the plans)

- **Cost-based choice.** PostgreSQL estimates each possible plan's cost from table statistics gathered by `ANALYZE` (row counts, value histograms, correlation). It picks the cheapest. An index is only used when the estimated number of matching rows is small enough. A sequential scan reads pages in order and is cheaper per page than random index access.
- **Join algorithms** in the plans:
  - *Nested Loop* (small outer side, indexed inner side: Q1 after);
  - *Hash Join* (larger unsorted inputs: Q5);
  - *Merge Join* (both inputs sorted).
- **Bitmap scans** (Q2 baseline, Q4) collect matching row locations from an index first, then read the table pages in physical order. This is the middle ground between an index scan and a sequential scan.
- **Statistics matter.** All timings were taken after `ANALYZE`. Without fresh statistics the planner can choose badly.
- **Buffers, not just milliseconds.** The "pages" column (8 kB buffers touched) is a hardware-independent measure of work. It shows the same story as the timings and does not depend on the laptop.

## Trade-offs and what I would do next

- **Every index slows down writes and uses disk** (see the cost table). Only indexes that serve a measured query were kept, and one I planned was dropped because the planner never used it.
- **The materialised view is stale between refreshes.** `REFRESH MATERIALIZED VIEW CONCURRENTLY` (enabled by the unique index) can run nightly without blocking readers. Management accepts yesterday's figures; clinical screens never read the view.
- **Next steps at larger scale:**
  - range-partition `appointments` by month, so reports read only the relevant partitions and old months can be archived;
  - use `pg_stat_statements` (already enabled) to find the most expensive queries in production;
  - route reports to a read replica (Part 5).
