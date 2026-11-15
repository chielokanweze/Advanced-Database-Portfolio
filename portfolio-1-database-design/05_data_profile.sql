-- =====================================================================================
-- Portfolio 1 - Data profile: evidence that the seeded data is realistic and consistent
-- Run:  psql -U gc -d gracecare -f 05_data_profile.sql
-- =====================================================================================
SET search_path = gc, public;
\pset footer off

\echo '== Row counts and on-disk size per table =='
SELECT c.relname AS table_name,
       c.reltuples::bigint AS approx_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gc' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo '== Appointment status by period (data as-of Saturday 14 Nov 2026) =='
SELECT status, count(*) AS appointments,
       min(start_at)::date AS first_visit, max(start_at)::date AS last_visit
FROM appointments GROUP BY status ORDER BY status;

\echo '== Patient mix per department (children in Paediatrics, women in O&G) =='
SELECT dep.name AS department, count(*) AS visits,
       round(avg(date_part('year', age(a.start_at::date, p.date_of_birth)))::numeric, 1) AS avg_age,
       round(100.0 * avg((p.sex = 'F')::int), 0) AS pct_female
FROM appointments a JOIN patients p USING (patient_id)
JOIN doctors d USING (doctor_id) JOIN departments dep USING (dept_id)
GROUP BY dep.name ORDER BY visits DESC;

\echo '== Top 10 primary diagnoses =='
SELECT d.icd10_code, c.description, count(*) AS cases
FROM diagnoses d JOIN icd10_codes c ON c.code = d.icd10_code
WHERE d.is_primary GROUP BY 1, 2 ORDER BY cases DESC LIMIT 10;

\echo '== Lab results by flag and workflow status =='
SELECT result_flag, status, count(*) FROM lab_orders GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== Drugs below re-order level =='
SELECT name, stock_qty, reorder_level FROM drugs WHERE stock_qty < reorder_level ORDER BY name;

\echo '== Current bed occupancy per ward =='
SELECT w.name AS ward, count(b.bed_id) AS beds,
       count(a.admission_id) AS occupied,
       round(100.0 * count(a.admission_id) / count(b.bed_id), 0) AS pct_occupied
FROM wards w JOIN beds b USING (ward_id)
LEFT JOIN admissions a ON a.bed_id = b.bed_id AND a.discharged_at IS NULL
GROUP BY w.name ORDER BY w.name;

\echo '== Consistency checks (every number must be 0) =='
SELECT
  (SELECT count(*) FROM diagnoses d JOIN appointments a USING (appointment_id)
    WHERE a.status NOT IN ('CHECKED_IN','COMPLETED'))                         AS dx_on_unattended_visits,
  (SELECT count(*) FROM diagnoses d JOIN appointments a USING (appointment_id)
    JOIN patients p USING (patient_id) JOIN icd10_codes c ON c.code = d.icd10_code
    WHERE c.sex_restriction IS NOT NULL AND c.sex_restriction <> p.sex)       AS dx_sex_mismatch,
  (SELECT count(*) FROM appointments a JOIN patients p USING (patient_id)
    WHERE a.start_at < p.registered_at)                                        AS visits_before_registration,
  (SELECT count(*) FROM appointments a JOIN doctors d USING (doctor_id)
    JOIN departments dep USING (dept_id) JOIN patients p USING (patient_id)
    WHERE dep.name = 'Paediatrics' AND age(a.start_at::date, p.date_of_birth) >= interval '17 years') AS adults_in_paediatrics,
  (SELECT count(*) FROM appointments WHERE status = 'COMPLETED' AND NOT EXISTS
    (SELECT 1 FROM diagnoses d WHERE d.appointment_id = appointments.appointment_id AND d.is_primary)) AS completed_without_primary_dx;

\echo '== Example: one patient record =='
SELECT p.hospital_no, p.first_name || ' ' || p.last_name AS patient, p.sex,
       date_part('year', age(DATE '2026-11-14', p.date_of_birth)) AS age, p.genotype,
       a.start_at, dep.name AS department, a.status, d.icd10_code, c.description
FROM patients p
JOIN appointments a USING (patient_id)
JOIN doctors doc USING (doctor_id) JOIN departments dep USING (dept_id)
LEFT JOIN diagnoses d ON d.appointment_id = a.appointment_id AND d.is_primary
LEFT JOIN icd10_codes c ON c.code = d.icd10_code
WHERE p.hospital_no = 'GC00000042'
ORDER BY a.start_at;
