# MIT 8103 Advanced Database Systems: Individual Practical Portfolio

**Student:** _(name)_ · **Matric no:** _(number)_ · **Session:** 2026/2027, First Semester · **Programme:** Master of Information Technology, MIVA Open University

## Selected case study: GraceCare Specialist Hospital, Port Harcourt (simulated)

|                             |                                                                                                                                                                                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Organisation / scenario** | GraceCare Specialist Hospital, a simulated 98-bed private specialist hospital in Port Harcourt, Rivers State, Nigeria                                                                                                                                                                                         |
| **Nature of the business**  | Outpatient clinics (7 departments), emergency care, pharmacy, laboratory and inpatient wards (6 wards incl. ICU and maternity)                                                                                                                                                                                |
| **Users of the database**   | Front-desk staff, doctors, pharmacists, laboratory scientists, ward managers, hospital management (de-identified reports), auditors                                                                                                                                                                           |
| **Major data stored**       | Patients (incl. genotype and blood group), departments, doctors, appointments, ICD-10 diagnoses, drugs and stock, prescriptions, lab tests and results, wards, beds, admissions, and the audit trail                                                                                                          |
| **Key operations**          | Register a patient · book an appointment with no double booking · record a diagnosis · prescribe and dispense (stock correct under concurrency) · order, result and review lab tests (critical-result alerts) · admit and discharge (bed allocation) · retrieve a full patient history · management reporting |

All data is **synthetic** and generated reproducibly: 60,000 patients and about 123,000 appointments from 17 Nov 2025 to 31 Dec 2026, "as of" 14 Nov 2026. No real patient data is used. The design follows the **Nigeria Data Protection Act (NDPA) 2023**: least-privilege roles, a de-identified reporting view, and an audit trail.

The **same case study runs through all five portfolios**: one relational design is optimised, stressed under concurrency, re-modelled in NoSQL, and then distributed.
