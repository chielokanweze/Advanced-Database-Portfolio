-- =====================================================================================
-- Portfolio 1 - Role-based access control (least privilege)
-- Each database user group gets only what its job needs. Login users are then
-- created per person and granted ONE of these group roles, e.g.
--     CREATE ROLE ada_frontdesk LOGIN PASSWORD '...' IN ROLE gc_frontdesk;
-- =====================================================================================
\set ON_ERROR_STOP on
SET search_path = gc, public;

DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['gc_frontdesk','gc_clinician','gc_pharmacist','gc_lab','gc_reporting'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

REVOKE ALL ON SCHEMA gc FROM PUBLIC;
GRANT USAGE ON SCHEMA gc TO gc_frontdesk, gc_clinician, gc_pharmacist, gc_lab, gc_reporting;

-- Front desk: registration and booking only. No access to diagnoses, prescriptions or labs.
GRANT SELECT, INSERT                  ON patients        TO gc_frontdesk;
GRANT UPDATE (phone, blood_group, genotype) ON patients  TO gc_frontdesk;
GRANT SELECT, INSERT                  ON appointments    TO gc_frontdesk;
GRANT UPDATE (status, start_at, end_at) ON appointments  TO gc_frontdesk;
GRANT SELECT ON doctors, departments, v_patients         TO gc_frontdesk;

-- Clinicians: read the full record, write clinical notes.
GRANT SELECT ON ALL TABLES IN SCHEMA gc                  TO gc_clinician;
GRANT INSERT, UPDATE ON diagnoses, prescriptions         TO gc_clinician;
GRANT INSERT ON lab_orders                               TO gc_clinician;
GRANT UPDATE (status, reviewed_at, reviewed_by) ON lab_orders TO gc_clinician;
GRANT UPDATE (status) ON appointments                    TO gc_clinician;
GRANT INSERT, UPDATE (discharged_at) ON admissions       TO gc_clinician;
REVOKE SELECT ON audit_log FROM gc_clinician;            -- audit trail is for auditors only

-- Pharmacy: prescriptions and stock only.
GRANT SELECT ON prescriptions, drugs, patients           TO gc_pharmacist;
GRANT UPDATE (status, dispensed_at) ON prescriptions     TO gc_pharmacist;
GRANT UPDATE (stock_qty) ON drugs                        TO gc_pharmacist;

-- Laboratory: enter results; cannot see diagnoses or prescriptions.
GRANT SELECT ON lab_orders, lab_tests                    TO gc_lab;
GRANT UPDATE (status, result_value, resulted_at) ON lab_orders TO gc_lab;

-- Management reporting: de-identified data only.
GRANT SELECT ON v_visits_deidentified, departments, icd10_codes TO gc_reporting;

-- Identity columns need sequence USAGE for INSERT
GRANT USAGE ON ALL SEQUENCES IN SCHEMA gc TO gc_frontdesk, gc_clinician;
