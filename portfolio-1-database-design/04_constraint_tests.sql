-- =====================================================================================
-- Portfolio 1 - Constraint test suite
-- Proves that the business rules are enforced BY THE DATABASE, not just by an application.
-- Each test tries something that must be rejected (or allowed) and prints PASS / FAIL.
-- Everything runs inside one transaction that is rolled back, so the data is unchanged.
--
-- Run:  psql -U gc -d gracecare -f 04_constraint_tests.sql
-- =====================================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
SET search_path = gc, public;
SET client_min_messages = notice;
BEGIN;

-- T01: hospital number must be unique ------------------------------------------------
DO $$ BEGIN
    INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth)
    VALUES ('GC00000001', 'Test', 'Duplicate', 'F', '1990-01-01');
    RAISE NOTICE 'FAIL T01 duplicate hospital_no was accepted';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS T01 duplicate hospital_no rejected (unique_violation)';
END $$;

-- T02: hospital number format GC + 8 digits ------------------------------------------
DO $$ BEGIN
    INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth)
    VALUES ('XX12', 'Test', 'Format', 'F', '1990-01-01');
    RAISE NOTICE 'FAIL T02 badly formatted hospital_no accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T02 badly formatted hospital_no rejected (check_violation)';
END $$;

-- T03: date of birth cannot be in the future (trigger, because CHECK must be immutable)
DO $$ BEGIN
    INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth)
    VALUES ('GC99999901', 'Test', 'Future', 'M', current_date + 30);
    RAISE NOTICE 'FAIL T03 future date of birth accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T03 future date of birth rejected by trigger';
END $$;

-- T04: phone must be a Nigerian mobile number in +234 format ---------------------------
DO $$ BEGIN
    INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth, phone)
    VALUES ('GC99999902', 'Test', 'Phone', 'M', '1990-01-01', '0803 123 4567');
    RAISE NOTICE 'FAIL T04 invalid phone accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T04 invalid phone format rejected';
END $$;

-- T05: doctor double booking with an OVERLAPPING (not identical) slot -----------------
DO $$
DECLARE a appointments%ROWTYPE;
BEGIN
    SELECT * INTO a FROM appointments WHERE status = 'BOOKED' ORDER BY appointment_id LIMIT 1;
    INSERT INTO appointments (patient_id, doctor_id, start_at, end_at)
    VALUES ((SELECT min(patient_id) FROM patients WHERE patient_id <> a.patient_id),
            a.doctor_id, a.start_at + interval '15 minutes', a.end_at + interval '15 minutes');
    RAISE NOTICE 'FAIL T05 overlapping booking for doctor % accepted', a.doctor_id;
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'PASS T05 overlapping doctor booking rejected (exclusion constraint appt_no_doctor_overlap)';
END $$;

-- T06: patient cannot be booked with two doctors at the same time ----------------------
DO $$
DECLARE a appointments%ROWTYPE; other_doc int;
BEGIN
    SELECT * INTO a FROM appointments WHERE status = 'BOOKED' ORDER BY appointment_id LIMIT 1;
    -- a doctor who is free at that time
    SELECT d.doctor_id INTO other_doc FROM doctors d
    WHERE d.doctor_id <> a.doctor_id AND NOT EXISTS (
        SELECT 1 FROM appointments x WHERE x.doctor_id = d.doctor_id AND x.status <> 'CANCELLED'
          AND tstzrange(x.start_at, x.end_at) && tstzrange(a.start_at, a.end_at))
    LIMIT 1;
    INSERT INTO appointments (patient_id, doctor_id, start_at, end_at)
    VALUES (a.patient_id, other_doc, a.start_at, a.end_at);
    RAISE NOTICE 'FAIL T06 patient double booking accepted';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'PASS T06 patient booked twice at the same time rejected (appt_no_patient_overlap)';
END $$;

-- T07: a CANCELLED appointment frees the slot (constraint is partial: WHERE status <> 'CANCELLED')
DO $$
DECLARE a appointments%ROWTYPE;
BEGIN
    SELECT * INTO a FROM appointments WHERE status = 'BOOKED' ORDER BY appointment_id OFFSET 1 LIMIT 1;
    UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = a.appointment_id;
    INSERT INTO appointments (patient_id, doctor_id, start_at, end_at)
    VALUES ((SELECT min(patient_id) FROM patients WHERE patient_id <> a.patient_id
               AND NOT EXISTS (SELECT 1 FROM appointments x WHERE x.patient_id = patients.patient_id
                                 AND x.status <> 'CANCELLED'
                                 AND tstzrange(x.start_at, x.end_at) && tstzrange(a.start_at, a.end_at))),
            a.doctor_id, a.start_at, a.end_at);
    RAISE NOTICE 'PASS T07 slot re-booked after cancellation';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL T07 re-booking a cancelled slot failed: %', SQLERRM;
END $$;

-- T08: appointment must end after it starts -------------------------------------------
DO $$ BEGIN
    INSERT INTO appointments (patient_id, doctor_id, start_at, end_at)
    VALUES (1, 1, '2027-03-01 10:00+01', '2027-03-01 09:30+01');
    RAISE NOTICE 'FAIL T08 negative-length appointment accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T08 end_at before start_at rejected';
END $$;

-- T09: no diagnosis on a visit that has not happened -----------------------------------
DO $$ BEGIN
    INSERT INTO diagnoses (appointment_id, icd10_code, is_primary)
    VALUES ((SELECT min(appointment_id) FROM appointments WHERE status = 'BOOKED'), 'B54', true);
    RAISE NOTICE 'FAIL T09 diagnosis on a BOOKED appointment accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T09 diagnosis on a future (BOOKED) appointment rejected by trigger';
END $$;

-- T10: sex-restricted ICD-10 code (pregnancy) on a male patient ------------------------
DO $$ BEGIN
    INSERT INTO diagnoses (appointment_id, icd10_code)
    VALUES ((SELECT min(a.appointment_id) FROM appointments a JOIN patients p USING (patient_id)
             WHERE a.status = 'COMPLETED' AND p.sex = 'M'), 'Z34.9');
    RAISE NOTICE 'FAIL T10 pregnancy code on a male patient accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T10 Z34.9 (pregnancy) on a male patient rejected by trigger';
END $$;

-- T11: unknown ICD-10 code (foreign key to icd10_codes) ---------------------------------
DO $$ BEGIN
    INSERT INTO diagnoses (appointment_id, icd10_code)
    VALUES ((SELECT min(appointment_id) FROM appointments WHERE status = 'COMPLETED'), 'X99.9');
    RAISE NOTICE 'FAIL T11 unknown ICD-10 code accepted';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'PASS T11 unknown ICD-10 code rejected (foreign key)';
END $$;

-- T12: only one PRIMARY diagnosis per visit (partial unique index) ---------------------
DO $$
DECLARE v_appt bigint;
BEGIN
    SELECT d.appointment_id INTO v_appt FROM diagnoses d
    JOIN appointments a USING (appointment_id) JOIN patients p USING (patient_id)
    WHERE d.is_primary AND p.sex = 'F' AND d.icd10_code <> 'I10' LIMIT 1;
    INSERT INTO diagnoses (appointment_id, icd10_code, is_primary) VALUES (v_appt, 'I10', true);
    RAISE NOTICE 'FAIL T12 second primary diagnosis accepted';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS T12 second primary diagnosis rejected (uq_one_primary_diagnosis)';
END $$;

-- T13: stock can never go negative ------------------------------------------------------
DO $$ BEGIN
    UPDATE drugs SET stock_qty = stock_qty - 1000000 WHERE name = 'Ceftriaxone 1g';
    RAISE NOTICE 'FAIL T13 negative stock accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T13 negative stock rejected';
END $$;

-- T14: DISPENSED prescription must have a dispensed_at time ------------------------------
DO $$ BEGIN
    UPDATE prescriptions SET status = 'DISPENSED', dispensed_at = NULL
    WHERE prescription_id = (SELECT min(prescription_id) FROM prescriptions WHERE status = 'PRESCRIBED');
    RAISE NOTICE 'FAIL T14 DISPENSED without timestamp accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T14 DISPENSED without dispensed_at rejected';
END $$;

-- T15: lab flag is derived automatically from the reference ranges ---------------------
DO $$
DECLARE v_flag text;
BEGIN
    INSERT INTO lab_orders (appointment_id, test_id, status, result_value, resulted_at)
    VALUES ((SELECT min(appointment_id) FROM appointments WHERE status = 'COMPLETED'),
            (SELECT test_id FROM lab_tests WHERE code = 'K'), 'RESULTED', 7.4, now())
    RETURNING result_flag INTO v_flag;
    IF v_flag = 'CRITICAL' THEN
        RAISE NOTICE 'PASS T15 potassium 7.4 mmol/L automatically flagged CRITICAL (limit 6.2)';
    ELSE
        RAISE NOTICE 'FAIL T15 expected CRITICAL, got %', v_flag;
    END IF;
END $$;

-- T16: a result cannot be REVIEWED without a reviewer ----------------------------------
DO $$ BEGIN
    UPDATE lab_orders SET status = 'REVIEWED'
    WHERE order_id = (SELECT min(order_id) FROM lab_orders WHERE status = 'RESULTED');
    RAISE NOTICE 'FAIL T16 review without reviewer accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS T16 REVIEWED without reviewed_by/reviewed_at rejected';
END $$;

-- T17: a bed cannot hold two patients at once -------------------------------------------
DO $$
DECLARE v_bed int;
BEGIN
    SELECT bed_id INTO v_bed FROM admissions WHERE discharged_at IS NULL LIMIT 1;  -- occupied now
    INSERT INTO admissions (patient_id, bed_id, admitting_doctor_id, admitted_at, admission_reason)
    VALUES (1, v_bed, 1, now(), 'Test');
    RAISE NOTICE 'FAIL T17 occupied bed allocated again';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'PASS T17 occupied bed cannot be allocated (bed_not_double_occupied)';
END $$;

-- T18: clinical history cannot be deleted (ON DELETE RESTRICT protects the record) ----
DO $$ BEGIN
    DELETE FROM patients
    WHERE patient_id = (SELECT patient_id FROM appointments WHERE status = 'COMPLETED' LIMIT 1);
    RAISE NOTICE 'FAIL T18 patient with history was deleted';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'PASS T18 deleting a patient with clinical history rejected (RESTRICT)';
END $$;

-- T19: every change is written to the audit trail, with only the changed columns ----
DO $$
DECLARE v_id bigint; v_log audit_log%ROWTYPE;
BEGIN
    PERFORM set_config('gc.app_user', 'frontdesk.ada', true);
    SELECT appointment_id INTO v_id FROM appointments WHERE status = 'BOOKED' ORDER BY appointment_id DESC LIMIT 1;
    UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = v_id;
    SELECT * INTO v_log FROM audit_log WHERE table_name = 'appointments' AND row_pk = v_id;
    IF v_log.old_values = '{"status": "BOOKED"}'::jsonb AND v_log.new_values = '{"status": "CANCELLED"}'::jsonb THEN
        RAISE NOTICE 'PASS T19 audit row: % % -> % by app user "%"', v_log.table_name, v_log.old_values, v_log.new_values, v_log.app_user;
    ELSE
        RAISE NOTICE 'FAIL T19 audit row not as expected: %', row_to_json(v_log);
    END IF;
END $$;

-- T20: least privilege - front desk cannot read diagnoses -------------------------------
DO $$ BEGIN
    SET LOCAL ROLE gc_frontdesk;
    PERFORM 1 FROM diagnoses LIMIT 1;
    RESET ROLE;
    RAISE NOTICE 'FAIL T20 front desk could read diagnoses';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS T20 front-desk role denied access to diagnoses (insufficient_privilege)';
END $$;
RESET ROLE;

ROLLBACK;
