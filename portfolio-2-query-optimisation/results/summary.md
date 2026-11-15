# Portfolio 2 - benchmark results

- Server: `PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2) on x86_64-pc-linux-gnu` in Docker (Africa/Lagos time zone)
- Each time is the **median of 9 runs** after one warm-up run (server-side `Execution Time`, `EXPLAIN (ANALYZE, TIMING OFF)`).
- Pages = shared buffers touched in one run (hit + read), i.e. 8 kB blocks of work.
- Full plans: `results/plans/baseline__*.txt` and `results/plans/optimised__*.txt`.

## Query timings

| Query | Baseline ms | Optimised ms | Speed-up | Pages before -> after | Access path before | Access path after |
|---|---:|---:|---:|---:|---|---|
| Q1 patient history | 50.355 | 0.280 | **180x** | 9,419 -> 124 | Seq Scan on departments<br>Seq Scan on doctors<br>Seq Scan on appointments<br>Index Scan using patients_hospital_no_key on patients<br>Index Scan using uq_one_primary_diagnosis on diagnoses<br>Seq Scan on icd10_codes<br>Seq Scan on drugs<br>Index Scan using prescription_once_per_visit on prescriptions<br>Seq Scan on lab_tests<br>Seq Scan on lab_orders | Index Scan using patients_hospital_no_key on patients<br>Bitmap Heap Scan on appointments<br>Bitmap Index Scan on idx_appt_patient_start<br>Index Scan using doctors_pkey on doctors<br>Index Scan using departments_pkey on departments<br>Index Scan using uq_one_primary_diagnosis on diagnoses<br>Index Scan using icd10_codes_pkey on icd10_codes<br>Seq Scan on drugs<br>Index Scan using prescription_once_per_visit on prescriptions<br>Index Scan using idx_lab_orders_appointment on lab_orders<br>Seq Scan on lab_tests |
| Q2 doctor day list | 2.711 | 0.112 | **24x** | 1,580 -> 42 | Bitmap Heap Scan on appointments<br>Bitmap Index Scan on appt_no_doctor_overlap<br>Index Scan using patients_pkey on patients | Index Scan using idx_appt_start on appointments<br>Index Scan using patients_pkey on patients |
| Q3 critical results not reviewed | 7.164 | 0.066 | **109x** | 1,006 -> 36 | Seq Scan on lab_orders<br>Seq Scan on lab_tests<br>Index Scan using appointments_pkey on appointments<br>Index Scan using patients_pkey on patients | Index Scan using idx_lab_critical_unreviewed on lab_orders<br>Seq Scan on lab_tests<br>Index Scan using appointments_pkey on appointments<br>Index Scan using patients_pkey on patients |
| Q4 phone-number fragment search | 10.887 | 0.058 | **188x** | 732 -> 10 | Seq Scan on patients | Bitmap Heap Scan on patients<br>Bitmap Index Scan on idx_patients_phone_trgm |
| Q5 monthly report, indexes only | 55.756 | 55.005 | **1.0x** | 2,573 -> 1,462 | Seq Scan on diagnoses<br>Seq Scan on appointments<br>Seq Scan on icd10_codes<br>Seq Scan on doctors<br>Seq Scan on departments | Seq Scan on diagnoses<br>Index Scan using idx_appt_start on appointments<br>Seq Scan on icd10_codes<br>Seq Scan on doctors<br>Seq Scan on departments |
| Q5 monthly report, materialised view | 55.756 | 0.108 | **516x** | 2,573 -> 8 | Seq Scan on diagnoses<br>Seq Scan on appointments<br>Seq Scan on icd10_codes<br>Seq Scan on doctors<br>Seq Scan on departments | Seq Scan on mv_monthly_diagnoses |
| Q6 daily count as written (`start_at::date = ...`) | 15.798 | 12.596 | **1.3x** | 1,555 -> 118 | Seq Scan on appointments | Index Only Scan using idx_appt_start on appointments |
| Q6 daily count rewritten as a range (baseline column = Q6 as written, with index) | 12.596 | 0.038 | **331x** | 118 -> 3 | Index Only Scan using idx_appt_start on appointments | Index Only Scan using idx_appt_start on appointments |

## What the optimisations cost

| Object | Size |
|---|---:|
| `idx_appt_patient_start` | 3824 kB |
| `idx_patients_phone_trgm` | 2040 kB |
| `idx_lab_orders_appointment` | 1520 kB |
| `idx_appt_start` | 936 kB |
| `uq_mv_monthly_diagnoses` | 72 kB |
| `mv_monthly_diagnoses` | 64 kB |
| `idx_lab_critical_unreviewed` | 16 kB |

Table `appointments`: heap 12 MB, heap + all indexes 36 MB.

Write test: bulk INSERT of all 73,116 lab_orders rows into a trigger-free copy of the table, UNLOGGED to remove disk-flush noise, variants alternated, median of 10 rounds after a warm-up:

| Variant | ms |
|---|---:|
| No indexes | 38.5 |
| With the 2 indexes Part 2 adds to lab_orders | 112.8 |
| Index maintenance overhead | +193% |
