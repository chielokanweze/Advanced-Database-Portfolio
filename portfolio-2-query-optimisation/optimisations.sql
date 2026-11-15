-- =====================================================================================
-- Portfolio 2 - Optimisations. Each one is justified by a query in queries.sql.
-- Undo with drop_optimisations.sql.
-- =====================================================================================
SET search_path = gc, public;

-- Q1: the history query looks up lab orders by appointment. lab_orders has no other index
-- that starts with appointment_id (a visit may repeat a test, so there is no UNIQUE on it).
-- Without this index every visit in the history triggers a full scan of lab_orders.
CREATE INDEX IF NOT EXISTS idx_lab_orders_appointment ON lab_orders (appointment_id);

-- Q1: B-tree index for "all visits of one patient in time order".
-- (The GiST index behind the appt_no_patient_overlap EXCLUDE constraint could in principle find
--  a patient's rows, but the baseline plan shows the planner chose a sequential scan instead.)
CREATE INDEX IF NOT EXISTS idx_appt_patient_start ON appointments (patient_id, start_at);

-- Q2: a composite (doctor_id, start_at) index was tested first. For a one-day window the planner
-- preferred idx_appt_start (below) - only ~450 rows fall in one day - so the composite index was
-- never used and was removed: an unused index still costs disk space and slows every INSERT.

-- Q3: partial index - stores ONLY critical results that still need review (a handful of rows),
-- already ordered by resulted_at. Reviewed rows drop out of the index automatically.
CREATE INDEX IF NOT EXISTS idx_lab_critical_unreviewed ON lab_orders (resulted_at)
    WHERE result_flag = 'CRITICAL' AND status = 'RESULTED';

-- Q4: a B-tree cannot help LIKE '%...%' (leading wildcard). A trigram GIN index can.
CREATE INDEX IF NOT EXISTS idx_patients_phone_trgm ON patients USING gin (phone gin_trgm_ops);

-- Q5 + Q6: range filters on visit time.
CREATE INDEX IF NOT EXISTS idx_appt_start ON appointments (start_at);

-- Q5: management reports do not need second-by-second freshness. Pre-aggregate once
-- (e.g. nightly: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_diagnoses;).
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_monthly_diagnoses AS
SELECT date_trunc('month', a.start_at)::date AS month,
       dep.name                              AS department,
       c.description                         AS diagnosis,
       count(*)                              AS cases
FROM appointments a
JOIN diagnoses d     ON d.appointment_id = a.appointment_id AND d.is_primary
JOIN icd10_codes c   ON c.code = d.icd10_code
JOIN doctors doc     ON doc.doctor_id = a.doctor_id
JOIN departments dep ON dep.dept_id = doc.dept_id
GROUP BY 1, 2, 3;
-- a unique index is required for REFRESH ... CONCURRENTLY (readers are not blocked)
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_monthly_diagnoses ON mv_monthly_diagnoses (month, department, diagnosis);

ANALYZE;
