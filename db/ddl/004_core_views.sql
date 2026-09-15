-- 004_core_views.sql — D1-D3 view operasional (scoping guru, dua angka siswa, kuota kelas)

-- scope akses guru: hanya kelas yang ditugaskan padanya SAAT INI (NFR cakupan akses)
CREATE OR REPLACE VIEW delivery.v_teacher_section AS
SELECT ta.staff_id,
       ta.section_id,
       ta.role,
       s.centre_id,
       s.program_id
FROM   delivery.teacher_assignment ta
JOIN   delivery.class_section s ON s.id = ta.section_id
WHERE  ta.valid_from <= current_date
  AND (ta.valid_to IS NULL OR ta.valid_to >= current_date)
  AND s.status = 'active';

-- "jumlah siswa per centre" = jumlah PENDAFTARAN aktif (rule #1)
CREATE OR REPLACE VIEW identity.v_student_count_per_centre AS
SELECT c.id AS centre_id, c.name AS centre_name,
       count(*) AS enrollment_count          -- label UI: "Pendaftaran aktif"
FROM   identity.enrollment e
JOIN   identity.centre c ON c.id = e.teaching_centre_id
WHERE  e.status = 'active'
GROUP  BY c.id, c.name;

-- "jumlah siswa organisasi" = ORANG unik (rule #1) — nilainya TIDAK sama dengan total per centre
CREATE OR REPLACE VIEW identity.v_unique_student_org AS
SELECT count(DISTINCT e.student_id) AS unique_student_count
FROM   identity.enrollment e
WHERE  e.status = 'active';

-- minimal 3 kelas/hari per guru (fakta 3.1) & 5-8 guru per coordinator (3.5)
CREATE OR REPLACE VIEW delivery.v_teacher_daily_load AS
SELECT ts.staff_id, s.centre_id, ts.section_id, sl.day_of_week, count(*) OVER (PARTITION BY ts.staff_id, sl.day_of_week) AS classes_that_day
FROM   delivery.v_teacher_section ts
JOIN   delivery.schedule_slot sl ON sl.section_id = ts.section_id
JOIN   delivery.class_section s  ON s.id = ts.section_id;

-- jumlah meeting aktual vs planned per siklus (deteksi kurang/lebih sebelum lock)
CREATE OR REPLACE VIEW delivery.v_cycle_meeting_progress AS
SELECT cy.id AS cycle_id, cy.meetings_planned,
       count(m.id) FILTER (WHERE m.status = 'held')    AS held,
       count(m.id) FILTER (WHERE m.status = 'scheduled') AS upcoming,
       count(m.id) FILTER (WHERE m.is_makeup)           AS makeup_count,
       count(m.id) FILTER (WHERE m.deferred_from_meeting_id IS NOT NULL) AS deferred_count
FROM   delivery.cycle cy
LEFT   JOIN delivery.meeting m ON m.cycle_id = cy.id
GROUP  BY cy.id, cy.meetings_planned;
