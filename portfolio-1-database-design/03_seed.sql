-- =====================================================================================
-- Portfolio 1 - Synthetic, reproducible test data for GraceCare
--
-- * 100% synthetic: no real patient data is used (NDPA 2023).
-- * Reproducible: setseed() makes every run produce the same data.
-- * Clinically coherent: diagnoses depend on the department and the patient's sex,
--   prescriptions and lab tests depend on the diagnosis, children go to Paediatrics,
--   pregnant women to Obstetrics, nobody is booked before they were born/registered.
-- * "As-of" date of the data set: Saturday 14 November 2026. Earlier visits are
--   COMPLETED / NO_SHOW / CANCELLED; later ones (to 31 Dec 2026) are BOOKED.
--
-- Approximate volumes: 60,000 patients, ~125,000 appointments, ~110,000 diagnoses,
-- ~100,000 prescriptions, ~75,000 lab orders, ~3,500 admissions.
-- =====================================================================================
\set ON_ERROR_STOP on
\set asof '2026-11-14 00:00:00+01'
SET search_path = gc, public;
SELECT setseed(0.2026);

-- -------------------------------------------------------------------------------------
-- Helper functions (temporary, disappear at the end of the session)
-- -------------------------------------------------------------------------------------
CREATE FUNCTION pg_temp.pick(a text[]) RETURNS text
LANGUAGE sql VOLATILE AS $$ SELECT a[1 + floor(random() * cardinality(a))::int] $$;

-- weighted random choice: wpick(ARRAY['x','y'], ARRAY[90,10]) returns 'x' 90% of the time
CREATE FUNCTION pg_temp.wpick(vals text[], weights numeric[]) RETURNS text
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    total numeric := 0;
    r     numeric;
    acc   numeric := 0;
BEGIN
    FOR i IN 1 .. cardinality(weights) LOOP total := total + weights[i]; END LOOP;
    r := random() * total;
    FOR i IN 1 .. cardinality(vals) LOOP
        acc := acc + weights[i];
        IF r < acc THEN RETURN vals[i]; END IF;
    END LOOP;
    RETURN vals[cardinality(vals)];
END $$;

CREATE TEMP TABLE seed_names AS SELECT
    ARRAY['Chinedu','Emeka','Ifeanyi','Tonye','Dagogo','Kelechi','Sotonye','Ibifuro','Obinna','Babatunde',
          'Olumide','Musa','Ibrahim','Uche','Nnamdi','Ebuka','Tobi','Segun','Ikechukwu','Soala',
          'Daere','Boma','Femi','Yusuf','Chukwudi'] AS male,
    ARRAY['Chioma','Adaeze','Ngozi','Ebiere','Ibinabo','Amaka','Blessing','Peace','Funmilayo','Aisha',
          'Halima','Nneka','Ifeoma','Tamunoibi','Kemi','Zainab','Ugochi','Ebiye','Precious','Esther',
          'Ruth','Damiete','Folake','Hauwa','Chidinma'] AS female,
    ARRAY['Okafor','Wokoma','Amadi','Briggs','Nwosu','Jaja','Eze','Orlu','Harry','Dappa','Fubara',
          'Ogbonna','Abbey','Ikwuemesi','Adeyemi','Bello','Okonkwo','Georgewill','Ekine','Iyalla','Obi',
          'Nwachukwu','Okoye','Douglas','Davies','Horsfall','Adebayo','Mohammed','Ibe','Uzor','Tamuno',
          'Kalio','Opara','Ihunwo','Allison','Cookey','Pepple','Owhonda','Echendu','Nwankwo'] AS last;

-- -------------------------------------------------------------------------------------
-- Reference data
-- -------------------------------------------------------------------------------------
INSERT INTO departments (name, dept_type) VALUES
    ('Accident & Emergency',     'EMERGENCY'),
    ('General Outpatient',       'OUTPATIENT'),
    ('Paediatrics',              'OUTPATIENT'),
    ('Obstetrics & Gynaecology', 'OUTPATIENT'),
    ('Internal Medicine',        'OUTPATIENT'),
    ('Cardiology',               'OUTPATIENT'),
    ('Surgery',                  'THEATRE'),
    ('Intensive Care',           'INPATIENT');

INSERT INTO icd10_codes (code, description, chapter, sex_restriction) VALUES
    ('B54',   'Unspecified malaria',                                       'Infectious diseases', NULL),
    ('B50.9', 'Plasmodium falciparum malaria, unspecified',                'Infectious diseases', NULL),
    ('A01.0', 'Typhoid fever',                                             'Infectious diseases', NULL),
    ('A09',   'Infectious gastroenteritis and colitis, unspecified',       'Infectious diseases', NULL),
    ('B05.9', 'Measles without complication',                              'Infectious diseases', NULL),
    ('B20',   'HIV disease resulting in infectious and parasitic diseases','Infectious diseases', NULL),
    ('J06.9', 'Acute upper respiratory infection, unspecified',            'Respiratory system',  NULL),
    ('J18.9', 'Pneumonia, unspecified organism',                           'Respiratory system',  NULL),
    ('J45.9', 'Asthma, unspecified',                                       'Respiratory system',  NULL),
    ('I10',   'Essential (primary) hypertension',                          'Circulatory system',  NULL),
    ('I20.9', 'Angina pectoris, unspecified',                              'Circulatory system',  NULL),
    ('I21.9', 'Acute myocardial infarction, unspecified',                  'Circulatory system',  NULL),
    ('I48.9', 'Atrial fibrillation and atrial flutter, unspecified',       'Circulatory system',  NULL),
    ('I50.9', 'Heart failure, unspecified',                                'Circulatory system',  NULL),
    ('E11.9', 'Type 2 diabetes mellitus without complications',            'Endocrine and metabolic', NULL),
    ('E87.6', 'Hypokalaemia',                                              'Endocrine and metabolic', NULL),
    ('N18.9', 'Chronic kidney disease, unspecified',                       'Genitourinary system', NULL),
    ('N40',   'Hyperplasia of prostate',                                   'Genitourinary system', 'M'),
    ('N94.6', 'Dysmenorrhoea, unspecified',                                'Genitourinary system', 'F'),
    ('N76.0', 'Acute vaginitis',                                           'Genitourinary system', 'F'),
    ('D57.0', 'Sickle-cell anaemia with crisis',                           'Blood disorders',     NULL),
    ('D57.1', 'Sickle-cell anaemia without crisis',                        'Blood disorders',     NULL),
    ('K29.7', 'Gastritis, unspecified',                                    'Digestive system',    NULL),
    ('K35.8', 'Acute appendicitis, other and unspecified',                 'Digestive system',    NULL),
    ('K40.9', 'Inguinal hernia without obstruction or gangrene',           'Digestive system',    NULL),
    ('K80.2', 'Calculus of gallbladder without cholecystitis',             'Digestive system',    NULL),
    ('C50.9', 'Malignant neoplasm of breast, unspecified',                 'Neoplasms',           NULL),
    ('M54.5', 'Low back pain',                                             'Musculoskeletal',     NULL),
    ('R07.4', 'Chest pain, unspecified',                                   'Symptoms and signs',  NULL),
    ('S06.0', 'Concussion',                                                'Injury',              NULL),
    ('S52.5', 'Fracture of lower end of radius',                           'Injury',              NULL),
    ('T63.0', 'Toxic effect of snake venom',                               'Injury',              NULL),
    ('Z34.9', 'Supervision of normal pregnancy, unspecified',              'Health services',     'F'),
    ('O14.9', 'Pre-eclampsia, unspecified',                                'Pregnancy',           'F'),
    ('O24.4', 'Diabetes mellitus arising in pregnancy',                    'Pregnancy',           'F'),
    ('Z00.1', 'Routine child health examination',                          'Health services',     NULL),
    ('Z09',   'Follow-up examination after treatment',                     'Health services',     NULL);

INSERT INTO drugs (name, form, unit_price, stock_qty, reorder_level) VALUES
    ('Artemether/Lumefantrine 20/120mg', 'TABLET',     75,  4200, 1000),
    ('Artesunate 60mg',                  'INJECTION', 2500,  140,   50),
    ('Paracetamol 500mg',                'TABLET',      10, 22000, 5000),
    ('Ibuprofen 400mg',                  'TABLET',      25,  6000, 2000),
    ('Amoxicillin 500mg',                'CAPSULE',     60,  5200, 2000),
    ('Ciprofloxacin 500mg',              'TABLET',      90,  1800, 1000),
    ('Ceftriaxone 1g',                   'INJECTION', 1700,    45,   60),
    ('Metronidazole 400mg',              'TABLET',      30,  4000, 1500),
    ('Oral Rehydration Salts',           'SACHET',     100,   900,  500),
    ('Zinc sulphate 20mg',               'TABLET',      30,  1500,  500),
    ('Amlodipine 5mg',                   'TABLET',      40,  9000, 3000),
    ('Lisinopril 10mg',                  'TABLET',      55,  2500, 3000),
    ('Metformin 500mg',                  'TABLET',      35, 12000, 4000),
    ('Insulin glargine 100IU/mL',        'PEN',       9500,    18,   25),
    ('Ferrous sulphate 200mg',           'TABLET',       8, 15000, 4000),
    ('Folic acid 5mg',                   'TABLET',       5, 20000, 5000),
    ('Hydroxyurea 500mg',                'CAPSULE',    350,   900,  600),
    ('Salbutamol 100mcg',                'INHALER',   2800,    70,   40),
    ('Omeprazole 20mg',                  'CAPSULE',     45,  3000, 1500),
    ('Methyldopa 250mg',                 'TABLET',      60,  2000, 1000),
    ('Furosemide 40mg',                  'TABLET',      20,  4000, 1500),
    ('Aspirin 75mg',                     'TABLET',      12,  8000, 3000),
    ('Atorvastatin 20mg',                'TABLET',      80,  1200, 1500);

INSERT INTO lab_tests (code, name, unit, ref_low, ref_high, critical_low, critical_high, price) VALUES
    ('HB',    'Haemoglobin',                    'g/dL',         12,   17,    7,    20, 2000),
    ('WBC',   'White cell count',               'x10^9/L',       4,   11,    1,    30, 2500),
    ('RBG',   'Random blood glucose',           'mmol/L',      3.9,  7.8,  2.8,    25, 1200),
    ('HBA1C', 'Glycated haemoglobin (HbA1c)',   '%',             4,  5.6, NULL,  NULL, 6500),
    ('CREAT', 'Serum creatinine',               'umol/L',       60,  110, NULL,   600, 2500),
    ('K',     'Serum potassium',                'mmol/L',      3.5,  5.1,  2.8,   6.2, 2000),
    ('TROP',  'Troponin I (high-sensitivity)',  'ng/L',          0,   26, NULL,   500, 9000),
    ('MPD',   'Malaria parasite density',       'parasites/uL',  0,    0, NULL, 250000, 1500);

-- -------------------------------------------------------------------------------------
-- Doctors: 5 per department, specialty matches the department
-- -------------------------------------------------------------------------------------
INSERT INTO doctors (staff_no, first_name, last_name, sex, specialty, dept_id, mdcn_licence_no, email)
WITH spec(dept_name, specialty) AS (VALUES
    ('Accident & Emergency',     'Emergency Medicine'),
    ('General Outpatient',       'Family Medicine'),
    ('Paediatrics',              'Paediatrics'),
    ('Obstetrics & Gynaecology', 'Obstetrics & Gynaecology'),
    ('Internal Medicine',        'Internal Medicine'),
    ('Cardiology',               'Cardiology'),
    ('Surgery',                  'General Surgery'),
    ('Intensive Care',           'Anaesthesia & Critical Care')),
d AS MATERIALIZED (
    SELECT row_number() OVER (ORDER BY dep.dept_id, k) AS n, dep.dept_id, spec.specialty,
           CASE WHEN random() < 0.45 THEN 'F' ELSE 'M' END AS sex, random() AS r1, random() AS r2
    FROM departments dep JOIN spec ON spec.dept_name = dep.name
    CROSS JOIN generate_series(1, 5) k),
named AS MATERIALIZED (
    SELECT d.*, CASE d.sex WHEN 'F' THEN pg_temp.pick(sn.female) ELSE pg_temp.pick(sn.male) END AS first_name,
           pg_temp.pick(sn.last) AS last_name
    FROM d CROSS JOIN seed_names sn)
SELECT 'DR' || lpad(n::text, 4, '0'), first_name, last_name, sex, specialty, dept_id,
       'MDCN/' || (2004 + n % 18) || '/' || lpad((10000 + n * 379)::text, 5, '0'),
       lower(first_name || '.' || last_name || n) || '@gracecare.ng'
FROM named ORDER BY n;

-- -------------------------------------------------------------------------------------
-- Patients (60,000). Age mix: ~24% children, ~62% adults 16-64, ~14% aged 65+
-- -------------------------------------------------------------------------------------
INSERT INTO patients (hospital_no, first_name, last_name, sex, date_of_birth, phone, blood_group, genotype, registered_at)
WITH base AS MATERIALIZED (
    SELECT g,
           CASE WHEN random() < 0.52 THEN 'F' ELSE 'M' END AS sex,
           random() AS r_age, random() AS r_age2, random() AS r_reg
    FROM generate_series(1, 60000) g),
dob AS MATERIALIZED (
    SELECT b.*,
           (DATE '2026-11-14' - CASE WHEN r_age < 0.24 THEN floor(r_age2 * 16 * 365.25)
                                     WHEN r_age < 0.86 THEN floor((16 + r_age2 * 49) * 365.25)
                                     ELSE floor((65 + r_age2 * 30) * 365.25) END::int) AS date_of_birth
    FROM base b)
SELECT 'GC' || lpad(g::text, 8, '0'),
       CASE sex WHEN 'F' THEN pg_temp.pick(sn.female) ELSE pg_temp.pick(sn.male) END,
       pg_temp.pick(sn.last),
       sex,
       date_of_birth,
       '+234' || pg_temp.pick(ARRAY['70','80','81','90','91']) || lpad(floor(random() * 1e8)::bigint::text, 8, '0'),
       pg_temp.wpick(ARRAY['O+','A+','B+','AB+','O-','A-','B-','AB-'], ARRAY[51,22,20,3,2,1,0.7,0.3]),
       pg_temp.wpick(ARRAY['AA','AS','AC','SS','SC'], ARRAY[70,24,2.5,2.5,1]),
       CASE WHEN date_of_birth >= DATE '2025-11-01'
            THEN date_of_birth + interval '1 day 9 hours'                -- newborn registered at birth
            ELSE greatest(date_of_birth::timestamptz, TIMESTAMPTZ '2015-01-01 09:00+01')
                 + r_reg * (TIMESTAMPTZ '2025-11-01 09:00+01'
                            - greatest(date_of_birth::timestamptz, TIMESTAMPTZ '2015-01-01 09:00+01'))
       END
FROM dob CROSS JOIN seed_names sn
ORDER BY g;

-- -------------------------------------------------------------------------------------
-- Patient pools per department (children -> Paediatrics, women 16-45 -> O&G, ...)
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE seed_pool_member AS
SELECT pool, row_number() OVER (PARTITION BY pool ORDER BY patient_id) AS rn, patient_id
FROM (
    SELECT 'CHILD' AS pool, patient_id FROM patients WHERE age(DATE '2026-11-14', date_of_birth) < interval '16 years'
    UNION ALL
    SELECT 'WOMEN', patient_id FROM patients
     WHERE sex = 'F' AND age(DATE '2026-11-14', date_of_birth) BETWEEN interval '16 years' AND interval '45 years'
    UNION ALL
    SELECT 'ADULT', patient_id FROM patients WHERE age(DATE '2026-11-14', date_of_birth) >= interval '16 years'
    UNION ALL
    SELECT 'ALL', patient_id FROM patients
) x;
CREATE INDEX ON seed_pool_member (pool, rn);
CREATE TEMP TABLE seed_pool_size AS SELECT pool, count(*) AS n FROM seed_pool_member GROUP BY pool;

CREATE TEMP TABLE seed_dept (dept_name text, pool text, reasons text[]);
-- Visit "reason" records how the visit came about (not a symptom), so it can never
-- contradict the diagnosis that the doctor records later.
INSERT INTO seed_dept VALUES
    ('Accident & Emergency',     'ALL',   ARRAY['Walk-in emergency','Brought in by ambulance','Referred from primary health centre']),
    ('General Outpatient',       'ADULT', ARRAY['New complaint','Follow-up visit','Referred from primary health centre','Review of test results']),
    ('Paediatrics',              'CHILD', ARRAY['New complaint','Follow-up visit','Referred from primary health centre','Review of test results']),
    ('Obstetrics & Gynaecology', 'WOMEN', ARRAY['New complaint','Follow-up visit','Referred from primary health centre','Review of test results']),
    ('Internal Medicine',        'ADULT', ARRAY['New referral','Follow-up visit','Review of test results']),
    ('Cardiology',               'ADULT', ARRAY['New referral','Follow-up visit','Review of test results']),
    ('Surgery',                  'ADULT', ARRAY['New referral','Pre-operative assessment','Post-operative review']);

-- -------------------------------------------------------------------------------------
-- Appointments: weekday clinics 08:00-16:00 (16 x 30-minute slots) per doctor,
-- 17 Nov 2025 - 31 Dec 2026. ~80% of past slots used; future bookings thin out with distance.
-- Intensive Care doctors run no outpatient clinic (they appear in admissions).
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE seed_appt AS
WITH slots AS MATERIALIZED (
    SELECT d.doctor_id, sd.pool, sd.reasons, day::date AS day,
           ((day::date + time '08:00' + s * interval '30 minutes') AT TIME ZONE 'Africa/Lagos') AS start_at,
           random() AS r_keep, random() AS r_status, random() AS r_patient, random() AS r_booked
    FROM doctors d
    JOIN departments dep USING (dept_id)
    JOIN seed_dept sd ON sd.dept_name = dep.name
    CROSS JOIN generate_series(DATE '2025-11-17', DATE '2026-12-31', interval '1 day') day
    CROSS JOIN generate_series(0, 15) s
    WHERE extract(isodow FROM day) <= 5)
SELECT s.doctor_id, s.start_at, s.start_at + interval '30 minutes' AS end_at,
       m.patient_id,
       CASE WHEN s.start_at < :'asof'::timestamptz
            THEN CASE WHEN r_status < 0.84 THEN 'COMPLETED' WHEN r_status < 0.92 THEN 'NO_SHOW' ELSE 'CANCELLED' END
            ELSE CASE WHEN r_status < 0.93 THEN 'BOOKED' ELSE 'CANCELLED' END
       END AS status,
       pg_temp.pick(s.reasons) AS reason,
       least(:'asof'::timestamptz - interval '1 hour', s.start_at - r_booked * interval '30 days') AS booked_at
FROM slots s
JOIN seed_pool_size ps ON ps.pool = s.pool
JOIN seed_pool_member m ON m.pool = s.pool AND m.rn = 1 + floor(s.r_patient * ps.n)::int
WHERE s.r_keep < CASE WHEN s.start_at < :'asof'::timestamptz THEN 0.80
                      ELSE greatest(0.15, 0.80 - (s.day - DATE '2026-11-14') / 60.0) END;

-- ON CONFLICT DO NOTHING silently skips the few random rows that would put one patient in two
-- clinics at the same time (rejected by the appt_no_patient_overlap exclusion constraint).
INSERT INTO appointments (patient_id, doctor_id, start_at, end_at, status, reason, booked_at)
SELECT a.patient_id, a.doctor_id, a.start_at, a.end_at, a.status, a.reason,
       greatest(a.booked_at, p.registered_at)
FROM seed_appt a JOIN patients p USING (patient_id)
WHERE a.start_at > p.registered_at
ORDER BY a.start_at, a.doctor_id
ON CONFLICT DO NOTHING;

-- -------------------------------------------------------------------------------------
-- Diagnoses: weighted per department, filtered by the patient's sex
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE seed_dx (dept_name text, code text, weight int);
INSERT INTO seed_dx VALUES
    ('Accident & Emergency','S06.0',3),('Accident & Emergency','S52.5',3),('Accident & Emergency','R07.4',2),
    ('Accident & Emergency','B50.9',3),('Accident & Emergency','A09',2),('Accident & Emergency','T63.0',1),
    ('Accident & Emergency','J18.9',1),
    ('General Outpatient','B54',4),('General Outpatient','B50.9',3),('General Outpatient','A01.0',2),
    ('General Outpatient','J06.9',3),('General Outpatient','I10',3),('General Outpatient','E11.9',2),
    ('General Outpatient','M54.5',2),('General Outpatient','K29.7',2),('General Outpatient','N76.0',1),
    ('Paediatrics','B50.9',4),('Paediatrics','A09',3),('Paediatrics','J18.9',2),('Paediatrics','J06.9',3),
    ('Paediatrics','D57.1',1),('Paediatrics','D57.0',1),('Paediatrics','J45.9',1),('Paediatrics','B05.9',1),
    ('Paediatrics','Z00.1',2),
    ('Obstetrics & Gynaecology','Z34.9',6),('Obstetrics & Gynaecology','O14.9',1),
    ('Obstetrics & Gynaecology','O24.4',1),('Obstetrics & Gynaecology','N94.6',2),
    ('Obstetrics & Gynaecology','N76.0',2),
    ('Internal Medicine','I10',3),('Internal Medicine','E11.9',3),('Internal Medicine','N18.9',2),
    ('Internal Medicine','B20',1),('Internal Medicine','I50.9',1),('Internal Medicine','E87.6',1),
    ('Internal Medicine','B50.9',1),
    ('Cardiology','I10',4),('Cardiology','I20.9',2),('Cardiology','I21.9',1),('Cardiology','I48.9',1),
    ('Cardiology','I50.9',2),('Cardiology','R07.4',1),
    ('Surgery','K35.8',2),('Surgery','K40.9',2),('Surgery','K80.2',2),('Surgery','N40',1),
    ('Surgery','C50.9',1),('Surgery','S52.5',1),('Surgery','Z09',2);

-- expand weights into rows so a uniform random row number gives a weighted choice
CREATE TEMP TABLE seed_dx_member AS
SELECT dep.dept_id, sx.sex, row_number() OVER (PARTITION BY dep.dept_id, sx.sex ORDER BY x.code, k) AS rn, x.code
FROM seed_dx x
JOIN departments dep ON dep.name = x.dept_name
JOIN icd10_codes c ON c.code = x.code
CROSS JOIN (VALUES ('M'), ('F')) sx(sex)
CROSS JOIN LATERAL generate_series(1, x.weight) k
WHERE c.sex_restriction IS NULL OR c.sex_restriction = sx.sex;
CREATE TEMP TABLE seed_dx_size AS SELECT dept_id, sex, count(*) AS n FROM seed_dx_member GROUP BY 1, 2;

-- primary diagnosis for every completed visit
INSERT INTO diagnoses (appointment_id, icd10_code, is_primary, notes, recorded_at)
WITH v AS MATERIALIZED (
    SELECT a.appointment_id, a.end_at, doc.dept_id, p.sex, random() AS r
    FROM appointments a JOIN doctors doc USING (doctor_id) JOIN patients p USING (patient_id)
    WHERE a.status = 'COMPLETED')
SELECT v.appointment_id, m.code, true, 'Synthetic record', v.end_at - interval '5 minutes'
FROM v
JOIN seed_dx_size s   ON s.dept_id = v.dept_id AND s.sex = v.sex
JOIN seed_dx_member m ON m.dept_id = v.dept_id AND m.sex = v.sex AND m.rn = 1 + floor(v.r * s.n)::int
ORDER BY v.appointment_id;

-- ~12% of visits get a secondary diagnosis (duplicates of the primary are skipped)
INSERT INTO diagnoses (appointment_id, icd10_code, is_primary, notes, recorded_at)
WITH v AS MATERIALIZED (
    SELECT a.appointment_id, a.end_at, doc.dept_id, p.sex, random() AS r
    FROM appointments a JOIN doctors doc USING (doctor_id) JOIN patients p USING (patient_id)
    WHERE a.status = 'COMPLETED' AND random() < 0.12)
SELECT v.appointment_id, m.code, false, 'Synthetic record (secondary)', v.end_at - interval '4 minutes'
FROM v
JOIN seed_dx_size s   ON s.dept_id = v.dept_id AND s.sex = v.sex
JOIN seed_dx_member m ON m.dept_id = v.dept_id AND m.sex = v.sex AND m.rn = 1 + floor(v.r * s.n)::int
ORDER BY v.appointment_id
ON CONFLICT DO NOTHING;

-- -------------------------------------------------------------------------------------
-- Prescriptions follow the primary diagnosis
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE seed_dx_drug (code text, drug text, dosage text, qty int, prob numeric);
INSERT INTO seed_dx_drug VALUES
    ('B54',  'Artemether/Lumefantrine 20/120mg','4 tabs twice daily x 3 days',24,0.95),
    ('B54',  'Paracetamol 500mg','1g eight-hourly x 3 days',18,0.70),
    ('B50.9','Artemether/Lumefantrine 20/120mg','4 tabs twice daily x 3 days',24,0.95),
    ('B50.9','Paracetamol 500mg','1g eight-hourly x 3 days',18,0.70),
    ('A01.0','Ciprofloxacin 500mg','500mg twice daily x 14 days',28,0.90),
    ('A09',  'Oral Rehydration Salts','1 sachet after each loose stool',10,0.90),
    ('A09',  'Zinc sulphate 20mg','20mg daily x 10 days',10,0.80),
    ('J06.9','Paracetamol 500mg','1g eight-hourly x 3 days',18,0.80),
    ('J18.9','Amoxicillin 500mg','500mg eight-hourly x 7 days',21,0.90),
    ('J45.9','Salbutamol 100mcg','2 puffs as needed',1,0.95),
    ('B05.9','Paracetamol 500mg','500mg eight-hourly x 4 days',12,0.70),
    ('D57.1','Folic acid 5mg','5mg daily',30,0.90),
    ('D57.1','Hydroxyurea 500mg','500mg daily',30,0.50),
    ('D57.0','Paracetamol 500mg','1g eight-hourly x 3 days',18,0.90),
    ('D57.0','Folic acid 5mg','5mg daily',30,0.60),
    ('Z34.9','Ferrous sulphate 200mg','200mg daily',30,0.85),
    ('Z34.9','Folic acid 5mg','5mg daily',30,0.85),
    ('O14.9','Methyldopa 250mg','250mg eight-hourly',60,0.95),
    ('O24.4','Insulin glargine 100IU/mL','10 units at night',1,0.90),
    ('N94.6','Ibuprofen 400mg','400mg eight-hourly with food x 3 days',9,0.80),
    ('N76.0','Metronidazole 400mg','400mg twice daily x 7 days',14,0.85),
    ('I10',  'Amlodipine 5mg','5mg daily',30,0.80),
    ('I10',  'Lisinopril 10mg','10mg daily',30,0.40),
    ('E11.9','Metformin 500mg','500mg twice daily',60,0.90),
    ('N18.9','Furosemide 40mg','40mg daily',30,0.60),
    ('I50.9','Furosemide 40mg','40mg daily',30,0.90),
    ('I50.9','Lisinopril 10mg','10mg daily',30,0.50),
    ('I20.9','Aspirin 75mg','75mg daily',30,0.90),
    ('I20.9','Atorvastatin 20mg','20mg at night',30,0.80),
    ('I21.9','Aspirin 75mg','75mg daily',30,0.95),
    ('I21.9','Atorvastatin 20mg','20mg at night',30,0.95),
    ('K29.7','Omeprazole 20mg','20mg daily x 4 weeks',28,0.90),
    ('M54.5','Ibuprofen 400mg','400mg eight-hourly with food x 7 days',21,0.80),
    ('K35.8','Ceftriaxone 1g','1g daily IV x 3 days',3,0.90),
    ('S06.0','Paracetamol 500mg','1g eight-hourly x 3 days',18,0.80),
    ('S52.5','Ibuprofen 400mg','400mg eight-hourly with food x 7 days',21,0.80),
    ('K80.2','Ibuprofen 400mg','400mg eight-hourly with food x 3 days',9,0.50);

INSERT INTO prescriptions (appointment_id, drug_id, dosage, quantity, status, prescribed_at, dispensed_at)
WITH p AS MATERIALIZED (
    SELECT d.appointment_id, dr.drug_id, m.dosage, m.qty, a.start_at, a.end_at,
           random() AS r_status, random() AS r_delay
    FROM diagnoses d
    JOIN appointments a USING (appointment_id)
    JOIN seed_dx_drug m ON m.code = d.icd10_code
    JOIN drugs dr ON dr.name = m.drug
    WHERE d.is_primary AND random() < m.prob),
s AS (
    SELECT p.*,
           CASE WHEN r_status < 0.04 THEN 'CANCELLED'
                WHEN start_at >= :'asof'::timestamptz - interval '1 day' AND r_status < 0.60 THEN 'PRESCRIBED'
                ELSE 'DISPENSED' END AS status
    FROM p)
SELECT appointment_id, drug_id, dosage, qty, status, end_at - interval '2 minutes',
       CASE WHEN status = 'DISPENSED' THEN end_at + (10 + r_delay * 110) * interval '1 minute' END
FROM s
ORDER BY appointment_id;

-- -------------------------------------------------------------------------------------
-- Laboratory orders and results (result_flag is filled in by the lab_flag trigger)
-- -------------------------------------------------------------------------------------
-- side: which direction an abnormal result usually goes for this diagnosis (H = high, L = low)
CREATE TEMP TABLE seed_dx_lab (code text, test_code text, abnormal_rate numeric, side char(1));
INSERT INTO seed_dx_lab VALUES
    ('B54','MPD',0.90,'H'),   ('B50.9','MPD',0.92,'H'), ('B50.9','HB',0.30,'L'),
    ('A01.0','WBC',0.30,'H'), ('J18.9','WBC',0.60,'H'), ('B20','WBC',0.40,'L'),
    ('E11.9','RBG',0.60,'H'), ('E11.9','HBA1C',0.70,'H'), ('O24.4','RBG',0.60,'H'),
    ('I10','CREAT',0.15,'H'), ('I10','K',0.10,'H'),
    ('N18.9','CREAT',0.95,'H'), ('N18.9','K',0.40,'H'),
    ('I50.9','CREAT',0.40,'H'), ('I50.9','K',0.30,'L'), ('E87.6','K',0.95,'L'),
    ('R07.4','TROP',0.10,'H'), ('I20.9','TROP',0.15,'H'), ('I21.9','TROP',0.95,'H'),
    ('Z34.9','HB',0.20,'L'),  ('D57.0','HB',0.90,'L'), ('D57.1','HB',0.60,'L'),
    ('O14.9','CREAT',0.30,'H');

INSERT INTO lab_orders (appointment_id, test_id, ordered_at, status, result_value, resulted_at, reviewed_at, reviewed_by)
WITH o AS MATERIALIZED (
    SELECT d.appointment_id, a.doctor_id, a.start_at, t.test_id, t.code AS test_code,
           t.ref_low, t.ref_high, t.critical_low, t.critical_high, m.abnormal_rate, m.side,
           random() AS r_kind, random() AS r_side, random() AS r_val, random() AS r_tat, random() AS r_rev
    FROM diagnoses d
    JOIN appointments a USING (appointment_id)
    JOIN seed_dx_lab m ON m.code = d.icd10_code
    JOIN lab_tests t   ON t.code = m.test_code
    WHERE d.is_primary AND random() < 0.85),
v AS MATERIALIZED (
    SELECT o.*,
           round(CASE
               -- ~1.5% of all results are critical (life-threatening) values
               WHEN r_kind < 0.015 AND (side = 'H' OR critical_low IS NULL) AND critical_high IS NOT NULL
                    THEN critical_high * (1.02 + r_val * 0.6)
               WHEN r_kind < 0.015 AND critical_low IS NOT NULL
                    THEN critical_low * (0.60 + r_val * 0.38)
               -- abnormal but not critical, in the direction typical for the diagnosis
               WHEN r_kind < abnormal_rate AND side = 'H'
                    THEN ref_high + (coalesce(critical_high, ref_high * 1.6 + 1) - ref_high) * (0.05 + r_val * 0.9)
               WHEN r_kind < abnormal_rate AND side = 'L'
                    THEN ref_low - (ref_low - coalesce(critical_low, ref_low * 0.6)) * (0.05 + r_val * 0.9)
               -- normal result
               ELSE ref_low + (ref_high - ref_low) * r_val
           END::numeric, 2) AS result_value,
           start_at + interval '20 minutes' AS ordered_at,
           start_at + interval '20 minutes' + (2 + r_tat * 4) * interval '1 hour' AS resulted_at
    FROM o)
SELECT appointment_id, test_id, ordered_at,
       CASE WHEN resulted_at + (1 + r_rev * 20) * interval '1 hour' < :'asof'::timestamptz AND r_rev > 0.008
            THEN 'REVIEWED' ELSE 'RESULTED' END,
       result_value, resulted_at,
       CASE WHEN resulted_at + (1 + r_rev * 20) * interval '1 hour' < :'asof'::timestamptz AND r_rev > 0.008
            THEN resulted_at + (1 + r_rev * 20) * interval '1 hour' END,
       CASE WHEN resulted_at + (1 + r_rev * 20) * interval '1 hour' < :'asof'::timestamptz AND r_rev > 0.008
            THEN doctor_id END
FROM v
ORDER BY ordered_at;

-- -------------------------------------------------------------------------------------
-- Wards, beds and admissions (back-to-back stays per bed; current admissions have no discharge)
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE seed_ward (ward_name text, dept_name text, prefix text, beds int, pool text, reasons text[]);
INSERT INTO seed_ward VALUES
    ('Intensive Care Unit', 'Intensive Care',           'ICU', 10, 'ADULT', ARRAY['Septic shock','Respiratory failure','Post-operative ventilation','Severe head injury']),
    ('Cardiac Care Unit',   'Cardiology',               'CCU',  8, 'ADULT', ARRAY['Acute myocardial infarction','Decompensated heart failure','Arrhythmia monitoring']),
    ('Medical Ward',        'Internal Medicine',        'MED', 24, 'ADULT', ARRAY['Severe malaria','Diabetic ketoacidosis','Stroke','Pneumonia','Acute kidney injury']),
    ('Surgical Ward',       'Surgery',                  'SUR', 20, 'ADULT', ARRAY['Appendicectomy','Hernia repair','Cholecystectomy','Fracture fixation']),
    ('Maternity Ward',      'Obstetrics & Gynaecology', 'MAT', 16, 'WOMEN', ARRAY['Labour and delivery','Caesarean section','Pre-eclampsia monitoring']),
    ('Paediatric Ward',     'Paediatrics',              'PAE', 20, 'CHILD', ARRAY['Severe malaria','Sickle-cell crisis','Gastroenteritis with dehydration','Pneumonia']);

INSERT INTO wards (dept_id, name)
SELECT dep.dept_id, sw.ward_name FROM seed_ward sw JOIN departments dep ON dep.name = sw.dept_name;

INSERT INTO beds (ward_id, bed_label)
SELECT w.ward_id, sw.prefix || '-' || lpad(k::text, 2, '0')
FROM seed_ward sw JOIN wards w ON w.name = sw.ward_name
CROSS JOIN LATERAL generate_series(1, sw.beds) k;

INSERT INTO admissions (patient_id, bed_id, admitting_doctor_id, admitted_at, discharged_at, admission_reason)
WITH stays AS MATERIALIZED (
    SELECT b.bed_id, w.dept_id, sw.pool, sw.reasons,
           TIMESTAMPTZ '2025-11-17 10:00+01' + k * interval '8 days' + random() * interval '1 day' AS admitted_at,
           interval '1 day' + random() * interval '5 days 12 hours' AS los,
           random() AS r_skip, random() AS r_patient
    FROM beds b JOIN wards w USING (ward_id) JOIN seed_ward sw ON sw.ward_name = w.name
    CROSS JOIN generate_series(0, 45) k),
picked AS MATERIALIZED (
    SELECT s.*, m.patient_id,
           (SELECT doctor_id FROM doctors d WHERE d.dept_id = s.dept_id AND s.bed_id IS NOT NULL
            ORDER BY random() LIMIT 1) AS doctor_id
    FROM stays s
    JOIN seed_pool_size ps ON ps.pool = s.pool
    JOIN seed_pool_member m ON m.pool = s.pool AND m.rn = 1 + floor(s.r_patient * ps.n)::int
    WHERE s.r_skip > 0.15 AND s.admitted_at < :'asof'::timestamptz)
SELECT pk.patient_id, pk.bed_id, pk.doctor_id, pk.admitted_at,
       CASE WHEN pk.admitted_at + pk.los < :'asof'::timestamptz THEN pk.admitted_at + pk.los END,
       pg_temp.pick(pk.reasons)
FROM picked pk JOIN patients p USING (patient_id)
WHERE pk.admitted_at > p.registered_at
ORDER BY pk.admitted_at
ON CONFLICT DO NOTHING;

-- planner statistics for the new data
ANALYZE;

-- summary
SELECT 'patients' AS table_name, count(*) AS rows FROM patients
UNION ALL SELECT 'doctors', count(*) FROM doctors
UNION ALL SELECT 'appointments', count(*) FROM appointments
UNION ALL SELECT 'diagnoses', count(*) FROM diagnoses
UNION ALL SELECT 'prescriptions', count(*) FROM prescriptions
UNION ALL SELECT 'lab_orders', count(*) FROM lab_orders
UNION ALL SELECT 'admissions', count(*) FROM admissions
UNION ALL SELECT 'audit_log', count(*) FROM audit_log;
