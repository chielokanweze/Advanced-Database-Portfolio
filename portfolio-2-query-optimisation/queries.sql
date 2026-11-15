-- =====================================================================================
-- Portfolio 2 - Workload queries for GraceCare
-- Each block starts with "-- name: <id>". run_benchmark.py reads this file, runs every
-- query before and after optimisation, and stores the plans and timings in results/.
-- The queries can also be pasted into psql one by one.
-- =====================================================================================

-- name: q1_patient_history
-- Front desk / doctor: complete history for one patient (visits, diagnosis, drugs, lab results).
SELECT a.start_at,
       dep.name                                  AS department,
       'Dr ' || doc.last_name                    AS doctor,
       a.status,
       d.icd10_code,
       c.description                             AS diagnosis,
       (SELECT string_agg(dr.name || ' x' || pr.quantity, '; ' ORDER BY dr.name)
          FROM prescriptions pr JOIN drugs dr USING (drug_id)
         WHERE pr.appointment_id = a.appointment_id)                         AS prescriptions,
       (SELECT string_agg(t.code || '=' || l.result_value || ' ' || l.result_flag, '; ' ORDER BY t.code)
          FROM lab_orders l JOIN lab_tests t USING (test_id)
         WHERE l.appointment_id = a.appointment_id)                          AS lab_results
FROM patients p
JOIN appointments a   USING (patient_id)
JOIN doctors doc      USING (doctor_id)
JOIN departments dep  ON dep.dept_id = doc.dept_id
LEFT JOIN diagnoses d ON d.appointment_id = a.appointment_id AND d.is_primary
LEFT JOIN icd10_codes c ON c.code = d.icd10_code
WHERE p.hospital_no = 'GC00012290'
ORDER BY a.start_at;

-- name: q2_doctor_day_list
-- Clinic: one doctor's patient list for Monday 16 November 2026.
SELECT a.start_at, p.hospital_no, p.first_name || ' ' || p.last_name AS patient, a.reason
FROM appointments a
JOIN patients p USING (patient_id)
WHERE a.doctor_id = 12
  AND a.start_at >= '2026-11-16 00:00+01' AND a.start_at < '2026-11-17 00:00+01'
  AND a.status <> 'CANCELLED'
ORDER BY a.start_at;

-- name: q3_critical_unreviewed
-- Patient safety alert: CRITICAL lab results that no doctor has reviewed yet (polled every minute).
SELECT l.order_id, p.hospital_no, t.name AS test, l.result_value, t.unit, l.resulted_at
FROM lab_orders l
JOIN lab_tests t     USING (test_id)
JOIN appointments a  USING (appointment_id)
JOIN patients p      USING (patient_id)
WHERE l.result_flag = 'CRITICAL' AND l.status = 'RESULTED'
ORDER BY l.resulted_at;

-- name: q4_phone_search
-- Front desk: patient phones in and gives only the last digits of their number.
SELECT hospital_no, first_name, last_name, phone
FROM patients
WHERE phone LIKE '%73591%';

-- name: q5_monthly_dx_report
-- Management: primary diagnoses per department per month, July-September 2026.
SELECT date_trunc('month', a.start_at)::date AS month,
       dep.name                              AS department,
       c.description                         AS diagnosis,
       count(*)                              AS cases
FROM appointments a
JOIN diagnoses d    ON d.appointment_id = a.appointment_id AND d.is_primary
JOIN icd10_codes c  ON c.code = d.icd10_code
JOIN doctors doc    ON doc.doctor_id = a.doctor_id
JOIN departments dep ON dep.dept_id = doc.dept_id
WHERE a.start_at >= '2026-07-01 00:00+01' AND a.start_at < '2026-10-01 00:00+01'
GROUP BY 1, 2, 3
ORDER BY 1, 2, cases DESC;

-- name: q5_monthly_dx_report_mv
-- Same report answered from the pre-aggregated materialised view (see optimisations.sql).
SELECT month, department, diagnosis, cases
FROM mv_monthly_diagnoses
WHERE month >= DATE '2026-07-01' AND month < DATE '2026-10-01'
ORDER BY month, department, cases DESC;

-- name: q6a_daily_count_nonsargable
-- Anti-pattern: a function wrapped around the indexed column. The index on start_at
-- cannot be used because the planner would have to compute start_at::date for every row.
SELECT count(*) FROM appointments WHERE start_at::date = DATE '2026-11-13';

-- name: q6b_daily_count_sargable
-- Rewrite: the same question as a range on the bare column - the index can be used.
SELECT count(*) FROM appointments
WHERE start_at >= '2026-11-13 00:00+01' AND start_at < '2026-11-14 00:00+01';
