# Normalisation of the GraceCare schema

This document shows how the tables in `01_schema.sql` were derived. It starts from the paper form the clinic uses today, writes down the functional dependencies (FDs), and decomposes step by step. It then lists the few places where the design deliberately does **not** follow the normal forms, and explains why.

## 0. Starting point: the paper "clinic visit sheet" (unnormalised, UNF)

One sheet per visit, filled in by hand:

```
VisitSheet( visit_no, visit_time, hospital_no, patient_name, sex, dob, phone, genotype,
            doctor_staff_no, doctor_name, department_name, department_type,
            { icd10_code, diagnosis_text, primary? }*,                 <- repeating group
            { drug_name, drug_form, unit_price, dosage, quantity }*,   <- repeating group
            { test_code, test_name, unit, ref_low, ref_high, result, flag }* )  <- repeating group
```

Problems with this sheet as a single table:

- **Update anomaly:** a patient's phone number is copied onto every sheet. If they change number, every old sheet disagrees.
- **Insertion anomaly:** a new drug cannot be recorded until someone is prescribed it.
- **Deletion anomaly:** if the only visit that used a lab test is deleted, the test's reference range is lost.

## 1. Functional dependencies

These come from the hospital's business rules:

| # | Dependency | Business rule |
|---|---|---|
| FD1 | `hospital_no -> patient_name, sex, dob, phone, genotype, blood_group` | a hospital number identifies one patient |
| FD2 | `doctor_staff_no -> doctor_name, specialty, department_name, mdcn_licence_no` | |
| FD3 | `department_name -> department_type` | |
| FD4 | `visit_no -> visit_time, hospital_no, doctor_staff_no, status, reason` | |
| FD5 | `icd10_code -> diagnosis_text, chapter, sex_restriction` | ICD-10 is an international code list |
| FD6 | `visit_no, icd10_code -> primary?, notes` | |
| FD7 | `drug_name -> drug_form, unit_price, stock_qty` | |
| FD8 | `visit_no, drug_name -> dosage, quantity, status` | one prescription line per drug per visit |
| FD9 | `test_code -> test_name, unit, ref_low, ref_high, critical_low, critical_high` | |
| FD10 | `order_id -> visit_no, test_code, result_value, status` | a test may be repeated in one visit, so `(visit_no, test_code)` is **not** a key |
| FD11 | `test_code, result_value -> flag` | the flag is computed from the value and the reference ranges |
| FD12 | `doctor_id, time -> visit_no` (for non-cancelled visits) | a doctor sees one patient at a time |

## 2. First normal form (1NF): remove repeating groups

Each repeating group becomes its own relation, keyed by the visit plus the item:

- `Visit(visit_no, visit_time, hospital_no, patient..., doctor..., department...)`
- `VisitDiagnosis(visit_no, icd10_code, diagnosis_text, primary?)`, key = `(visit_no, icd10_code)`
- `VisitDrug(visit_no, drug_name, drug_form, unit_price, dosage, quantity)`, key = `(visit_no, drug_name)`
- `VisitTest(order_id, visit_no, test_code, test_name, unit, ref_low, ref_high, result, flag)`

Every column now holds one atomic value: there are no comma-separated lists. Names are also split into `first_name` and `last_name`, because the front desk searches by surname.

## 3. Second normal form (2NF): remove partial dependencies

A partial dependency exists when a non-key column depends on only part of a composite key:

- In `VisitDiagnosis`, `diagnosis_text` depends on `icd10_code` alone (FD5), not on `(visit_no, icd10_code)`. It moves to **`icd10_codes`**.
- In `VisitDrug`, `drug_form` and `unit_price` depend on `drug_name` alone (FD7). They move to **`drugs`**. What remains (`dosage`, `quantity`) depends on the whole key: this is **`prescriptions`**.

Note that a single-column surrogate key such as `prescription_id` does **not** by itself guarantee 2NF. The test has to use the *candidate* keys, and `(appointment_id, drug_id)` is still a candidate key of `prescriptions`. It is enforced with `UNIQUE (appointment_id, drug_id)`, and the 2NF check was done against it.

## 4. Third normal form (3NF): remove transitive dependencies

A transitive dependency is a chain `key -> A -> B` where A is not a key:

| Chain found | Fix |
|---|---|
| `visit_no -> hospital_no -> patient_name, phone, ...` (FD4 + FD1) | **`patients`** table; `appointments` keeps only `patient_id` |
| `visit_no -> doctor_staff_no -> doctor_name, department_name` (FD4 + FD2) | **`doctors`** table |
| `doctor -> department_name -> department_type` (FD2 + FD3) | **`departments`** table; `doctors` keeps only `dept_id` |
| `order_id -> test_code -> test_name, unit, ref ranges` (FD10 + FD9) | **`lab_tests`** table |
| `diagnosis -> icd10_code -> description` (FD5) | **`icd10_codes`** table. This is the classic mistake of storing the code and its description side by side. |

## 5. Boyce-Codd normal form (BCNF) check

For every table, every non-trivial FD has a candidate key on its left-hand side:

| Table | Candidate keys | BCNF |
|---|---|---|
| patients | `patient_id`, `hospital_no` | yes |
| doctors | `doctor_id`, `staff_no`, `mdcn_licence_no`, `email` | yes |
| departments | `dept_id`, `name` | yes |
| icd10_codes | `code` | yes |
| appointments | `appointment_id` (plus a *temporal* key: no overlapping doctor/time and patient/time, enforced by EXCLUDE constraints) | yes |
| diagnoses | `diagnosis_id`, `(appointment_id, icd10_code)` | yes |
| prescriptions | `prescription_id`, `(appointment_id, drug_id)` | yes |
| drugs, lab_tests, wards, beds | surrogate id + natural unique name/label | yes |
| lab_orders | `order_id` | yes, except the deliberate derived column below |
| admissions | `admission_id` (plus temporal keys on bed and patient) | yes |

## 6. Deliberate exceptions (controlled denormalisation)

| Where | What | Why it is acceptable |
|---|---|---|
| `lab_orders.result_flag` | Derived from `result_value` and the test's ranges (FD11), so strictly it is redundant | It powers the patient-safety alert "critical results not yet reviewed", which needs a small partial index (Part 2, Q3). The `lab_flag` **trigger recalculates it on every insert or update**, so it can never disagree with the value. |
| `drugs.stock_qty` | A running balance rather than the sum of a stock-movement ledger | Dispensing must check and decrement stock under concurrency (Part 3). A ledger would be more auditable; the `audit_log` trigger on `drugs` keeps the history of every change instead. |
| `audit_log.old_values / new_values` | `jsonb`, i.e. semi-structured | The trail must store rows from several different tables. It is append-only and never queried relationally. |
| Age | **Not stored**: derived in the `v_patients` view | Age changes every day, so a stored value would go stale. This is the opposite choice to `result_flag`: there is no indexing need and nothing to keep in sync. |
| MongoDB documents (Part 4) | Visits, diagnoses, prescriptions and labs embedded in the patient | A different model chosen for a different access pattern. See Part 4. |

## 7. What the constraints protect (summary)

| Rule | Mechanism |
|---|---|
| Identity of every row | `PRIMARY KEY` (identity columns) |
| No duplicate hospital numbers, licences, drug or test names | `UNIQUE` |
| Valid codes and formats (hospital no, phone, ICD-10 format, enums) | `CHECK` with regular expressions or lists |
| No doctor or patient double booking, no bed double occupancy | `EXCLUDE USING gist (... WITH =, tstzrange(...) WITH &&)` |
| One primary diagnosis per visit | partial `UNIQUE` index `WHERE is_primary` |
| Clinical history cannot be deleted | `FOREIGN KEY ... ON DELETE RESTRICT` |
| Workflow consistency (dispensed has a time, reviewed has a reviewer) | multi-column `CHECK` |
| Rules involving other rows/tables or "today" (DOB not in future, diagnosis only for attended visits, sex-specific codes) | `BEFORE` triggers |
| Accountability (who changed what) | `AFTER UPDATE OR DELETE` audit trigger + role-based privileges |

All of these are proven by `04_constraint_tests.sql` (20 tests; output in `results/constraint_tests_output.txt`).
