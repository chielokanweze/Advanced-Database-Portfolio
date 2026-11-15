-- Portfolio 2 - return to the un-optimised baseline (schema from Part 1 only).
SET search_path = gc, public;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_diagnoses;
DROP INDEX IF EXISTS idx_lab_orders_appointment,
                     idx_appt_patient_start,
                     idx_appt_doctor_start,      -- tested earlier, kept here so old runs are cleaned up
                     idx_lab_critical_unreviewed,
                     idx_patients_phone_trgm,
                     idx_appt_start;
ANALYZE;
