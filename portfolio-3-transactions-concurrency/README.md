# Portfolio 3: Transactions and concurrency

A hospital database is used by many people at the same moment: two pharmacists at two windows, three receptionists booking the same consultant, a lab scientist entering results while a doctor reads them. This part demonstrates, with **real concurrent PostgreSQL sessions**, what goes wrong without proper transaction control and how each problem is solved.

## Files

| File | Purpose |
|---|---|
| `procedures.sql` | `dispense_prescriptions()`: all-or-nothing dispensing with deadlock-free lock ordering. `allocate_bed()`: queue-style bed allocation with `SKIP LOCKED`. `icu_oncall`: on-call roster used by the write-skew demo. |
| `concurrency_demos.py` | Runs the seven demos A–G. Each thread has its own database connection. The script prints a millisecond timeline, and a monitor session reads `pg_stat_activity` to show who is waiting for whom. |
| `results/concurrency_demo_output.txt` | Full output of the last run (the evidence) |

Run (after Part 1): `docker compose run --rm tools python portfolio-3-transactions-concurrency/concurrency_demos.py`. It creates its own demo patient, visit, ward and on-call roster. Afterwards it deletes them and restores every drug's stock to its original value.

## What each demo shows

| Demo | Scenario at GraceCare | Problem / concept | Observed result |
|---|---|---|---|
| **A1** | Dispense Paracetamol x18 + Ceftriaxone x3 when only 2 Ceftriaxone are in stock | **Atomicity**: the Paracetamol update ran first, then the procedure raised an error | `ROLLBACK`; Paracetamol stock unchanged; both prescriptions still `PRESCRIBED` |
| **A2** | Same call after the stock is refilled | **Commit / durability** | Both drugs dispensed together; the audit trigger wrote the history |
| **A3** | Doctor orders 3 tests; the 2nd has an invalid test id | **Savepoint**: partial rollback inside one transaction | `ROLLBACK TO SAVEPOINT`; the other 2 orders committed |
| **B1** | Two pharmacists read stock 1000, then each writes `1000 - n` | **Lost update** (READ COMMITTED, read-modify-write in the application) | Final stock 976; it should be 958, so one dispensing was lost |
| **B2** | Same, with `SELECT ... FOR UPDATE` | **Pessimistic locking** | The monitor shows pharm2 *waiting* (`Lock:transactionid`), blocked by pharm1; result 958 |
| **B3** | Same, with `UPDATE ... SET stock_qty = stock_qty - n` | **Atomic update**: the database does the arithmetic on the latest row version | 958 |
| **B4** | Same read-modify-write, at REPEATABLE READ | **Optimistic concurrency** (MVCC snapshot + first-updater-wins) | Loser gets `40001 could not serialize access`, retries on a fresh snapshot; 958 |
| **C** | Stock report reads Amoxicillin twice while a delivery is booked in | **Non-repeatable read** | READ COMMITTED: 5200, then 7200. REPEATABLE READ: 5200 both times (one snapshot). |
| **D** | Rule: at least one ICU doctor on call. Both on-call doctors check the rule, then each signs *themself* off. | **Write skew**: the two transactions update *different* rows, so no row lock ever conflicts | REPEATABLE READ: both commit, 0 doctors on call (rule broken). SERIALIZABLE: SSI aborts one with `40001`; rule holds. |
| **E** | Two receptionists book the same doctor at 10:00–10:30 and 10:15–10:45 | **Constraint-based concurrency control** (exclusion constraint) | desk2's INSERT *waits* for desk1's open transaction, then fails with `23P01 exclusion_violation`. There is no race window. |
| **F1** | Two pharmacists each need two drugs, locking them in opposite order | **Deadlock** | After `deadlock_timeout` (1 s) PostgreSQL detects the cycle and aborts one transaction (`40P01`) |
| **F2** | Both lock in ascending `drug_id` order (as `dispense_prescriptions()` does) | **Deadlock prevention** by global lock ordering | pharm2 waits about 50 ms; both commit |
| **G** | 8 admission clerks, 5 free ICU beds, at the same instant | **`FOR UPDATE SKIP LOCKED`** (work-queue pattern) | 5 clerks get 5 *different* beds within about 20 ms; 3 are told "ward full" immediately, without waiting |

## Isolation levels in PostgreSQL (what the demos prove)

| Anomaly | READ COMMITTED (default) | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| Dirty read | not possible | not possible | not possible |
| Non-repeatable read | **possible** (C) | prevented (C) | prevented |
| Lost update (read-modify-write) | **possible** (B1) | prevented, loser must retry (B4) | prevented |
| Phantom read | possible | prevented in PostgreSQL (snapshot) | prevented |
| Write skew | possible | **possible** (D) | prevented (D) |

PostgreSQL implements these levels with **MVCC**:

- Every row version carries the transaction ids that created and deleted it (`xmin`/`xmax`).
- Readers use a snapshot and never block writers.
- Writers block other writers only on the *same* row (B2, E).
- REPEATABLE READ keeps one snapshot for the whole transaction. If another transaction has updated a row since that snapshot, an update to it fails with `40001` (B4).
- SERIALIZABLE adds **Serializable Snapshot Isolation (SSI)**. It tracks read/write dependencies (predicate "SIREAD" locks) and aborts one transaction when a dangerous cycle appears (D). It needs no extra blocking.

## Design choices for GraceCare

| Operation | Chosen technique | Reason |
|---|---|---|
| Dispensing (stock) | `dispense_prescriptions()`: one transaction, rows locked `FOR UPDATE` in `drug_id` order, stock decremented with an atomic `UPDATE`; `CHECK (stock_qty >= 0)` as a last line of defence | Correct under concurrency, cannot deadlock with itself, all-or-nothing |
| Booking | Exclusion constraint, READ COMMITTED | The database enforces the rule even if two applications race. No application-level locking is needed. |
| On-call / staffing rules (multi-row invariants) | SERIALIZABLE + automatic retry | Only SSI catches write skew. Retries are cheap because these transactions are rare and short. |
| Bed allocation | `SKIP LOCKED` | No clerk waits behind another, and no bed is given twice |
| Reports | REPEATABLE READ (read-only) | A consistent snapshot: totals add up even while data changes |

Applications that use REPEATABLE READ or SERIALIZABLE **must retry on SQLSTATE 40001** (shown in B4). This is the price of optimistic concurrency.
