-- checks/self_check.sql — jalankan SETELAH ddl 000..900 + seed, di DB uji:
--   psql -d beyond_test -f db/checks/self_check.sql
\set ON_ERROR_STOP on
SET search_path TO identity, curriculum, delivery, academics, quality, montessori, crm, finance, platform, public;

DO $$
DECLARE n int;
BEGIN
  -- 1. seed matriks Bagian 5 utuh
  SELECT count(*) INTO n FROM identity.program; ASSERT n = 7, format('program=%', n);
  SELECT count(*) INTO n FROM identity.centre;    ASSERT n = 7, format('centre=%', n);
  SELECT count(*) INTO n FROM academics.impact_value; ASSERT n = 6, 'IMPACT harus 6';

  -- 2. config versi awal = 10 meeting utk semua program
  SELECT count(*) INTO n FROM curriculum.program_cycle_config WHERE meetings_per_cycle = 10;
  ASSERT n = 7, 'cycle config awal 10 meeting';

  -- 3. baris konfigurasi lama tidak bisa di-UPDATE (rule #3)
  BEGIN
    UPDATE curriculum.program_cycle_config SET meetings_per_cycle = 8 WHERE effective_from = '2025-01-01';
    RAISE EXCEPTION 'SELF-CHECK-GAGAL: append-only config tidak menahan UPDATE';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'program_cycle_config%' THEN RAISE NOTICE 'append-only config OK';
      ELSE RAISE; END IF;
  END;

  -- 4. Jan-2027 transition = INSERT baru tanpa menyentuh lama (Q2)
  INSERT INTO curriculum.program_cycle_config (program_id, effective_from, meetings_per_cycle, classes_per_year, note)
  SELECT id, '2027-01-01', 8, 96, 'test transisi' FROM identity.program;
  SELECT count(*) INTO n FROM curriculum.program_cycle_config WHERE meetings_per_cycle = 10 AND effective_from = '2025-01-01';
  ASSERT n = 7, 'baris 2025 tetap utuh setelah transisi 2027';

  -- 5. dua angka siswa berbeda (Q1): buat 1 siswa 2 enrollment beda centre
  INSERT INTO identity.person (id, full_name) VALUES ('aaaaaaaa-0000-0000-0000-0000000000aa','Siswa Uji');
  INSERT INTO identity.student (person_id, student_code) VALUES ('aaaaaaaa-0000-0000-0000-0000000000aa','TEST-1');
  INSERT INTO identity.enrollment (id, student_id, program_id, teaching_centre_id, billing_centre_id, study_mode)
  VALUES ('bbbbbbbb-0000-0000-0000-0000000000b1','aaaaaaaa-0000-0000-0000-0000000000aa',
          '22222222-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000005','11111111-0000-0000-0000-000000000005','formal'),
         ('bbbbbbbb-0000-0000-0000-0000000000b2','aaaaaaaa-0000-0000-0000-0000000000aa',
          '22222222-0000-0000-0000-000000000006','11111111-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','non_formal');
  SELECT unique_student_count INTO n FROM v_unique_student_org;   ASSERT n = 1, 'org count = orang unik';
  SELECT sum(enrollment_count) INTO n FROM v_student_count_per_centre; ASSERT n = 2, 'centre count = pendaftaran';

  -- 6. promotion tidak memblokir, tapi catatan wajib saat flag (rule #10)
  BEGIN
    INSERT INTO academics.promotion_event (promotion_scope, enrollment_id, from_term_id, to_term_id, mode, below_readiness_flag, note_text)
    SELECT 'enrollment', 'bbbbbbbb-0000-0000-0000-0000000000b1', lt1.id, lt2.id, 'automatic', true, NULL
    FROM curriculum.level_term lt1, curriculum.level_term lt2 WHERE lt1.term_no=1 AND lt2.term_no=2 LIMIT 1;
    RAISE EXCEPTION 'check note_text saat flag GAGAL';
    EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'SELF CHECK OK';
END $$;

-- 7. guard periode terkunci (Q4): uji lewat siklus nyata
DO $$
DECLARE cy uuid; mt uuid; ta uuid;
BEGIN
  INSERT INTO delivery.academic_year (id, year, starts_on, ends_on)
  VALUES ('cccccccc-0000-0000-0000-0000000000c1', 2026, '2026-01-01','2026-12-31');
  INSERT INTO delivery.academic_month (id, year_id, seq_no, name, starts_on, ends_on)
  VALUES ('cccccccc-0000-0000-0000-0000000000m1','cccccccc-0000-0000-0000-0000000000c1',1,'Jan 2026','2026-01-04','2026-02-01');
  INSERT INTO delivery.class_section (id, code, program_id, centre_id, name)
  VALUES ('cccccccc-0000-0000-0000-0000000000s1','SEC-T1','22222222-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','Uji');
  INSERT INTO delivery.cycle (id, section_id, academic_month_id, config_id, meetings_planned)
  SELECT 'cccccccc-0000-0000-0000-0000000000y1','cccccccc-0000-0000-0000-0000000000s1',
         'cccccccc-0000-0000-0000-0000000000m1', pcc.id, 10
  FROM curriculum.program_cycle_config pcc WHERE pcc.program_id='22222222-0000-0000-0000-000000000001' AND effective_from='2025-01-01';
  INSERT INTO delivery.meeting (id, cycle_id, seq_no, scheduled_date)
  VALUES ('cccccccc-0000-0000-0000-0000000000e1','cccccccc-0000-0000-0000-0000000000y1',1,'2026-01-05');

  -- staff + user untuk uji
  INSERT INTO identity.person (id, full_name) VALUES ('dddddddd-0000-0000-0000-0000000000d1','Guru Uji');
  INSERT INTO identity.staff (person_id, staff_code) VALUES ('dddddddd-0000-0000-0000-0000000000d1','T-001');
  INSERT INTO identity.person (id, full_name) VALUES ('ffffffff-0000-0000-0000-0000000000f1','Admin Uji');
  INSERT INTO identity.user_account (id, person_id, username) VALUES ('ffffffff-0000-0000-0000-0000000000f2','ffffffff-0000-0000-0000-0000000000f1','admin_uji');
END $$;

-- uji guard periode terkunci (Q4)
DO $$
DECLARE u uuid; ta uuid; cy uuid;
BEGIN
  SELECT id INTO u FROM identity.user_account WHERE username='admin_uji';
  INSERT INTO academics.teaching_attendance (id, meeting_id, centre_id, staff_id, recorded_by, recorded_at)
  VALUES ('eeeeeeee-0000-0000-0000-0000000000e1','cccccccc-0000-0000-0000-0000000000e1',
          '11111111-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1', u, now())
  RETURNING id INTO ta;
  SELECT id INTO cy FROM delivery.cycle LIMIT 1;

  INSERT INTO platform.period_lock (lock_type, centre_id, cycle_id, locked_by)
  VALUES ('teaching_attendance','11111111-0000-0000-0000-000000000001', cy, u);

  BEGIN
    UPDATE academics.teaching_attendance SET role='substitute' WHERE id=ta;
    RAISE EXCEPTION 'LOCK GUARD GAGAL: update tembus setelah lock';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'Periode terkunci%' THEN RAISE NOTICE 'guard lock OK';
      ELSE RAISE; END IF;
  END;
END $$;

SELECT 'audit rows after guard test' AS chk, count(*) FROM platform.audit_log;
