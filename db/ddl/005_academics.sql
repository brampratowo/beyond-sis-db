-- 005_academics.sql — D4: presensi, penilaian, rapor, penempatan/kenaikan
-- Semua baris input guru: PK uuid DARI KLIEN (offline-first), UNIQUE pelindung duplikat sync, audit trigger (009).

-- ===== presensi =====
CREATE TABLE academics.attendance (
  id            uuid PRIMARY KEY,               -- dibuat di klien saat luring
  meeting_id    uuid NOT NULL REFERENCES delivery.meeting(id),
  centre_id     uuid NOT NULL REFERENCES identity.centre(id),   -- redundan sengaja: row-level scoping tanpa join
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  status        text NOT NULL CHECK (status IN ('present','absent','leave','sick')),
  note          text,
  recorded_by   uuid NOT NULL REFERENCES identity.user_account(id),
  recorded_at   timestamptz NOT NULL,           -- waktu lokal perangkat saat input
  device_id     uuid REFERENCES identity.device_registration(id),
  source        text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  updated_at    timestamptz,
  UNIQUE (meeting_id, enrollment_id)
);
COMMENT ON TABLE academics.attendance IS 'Input 1 layar 13 siswa, 1 batch INSERT. UNIQUE(meeting_id,enrollment_id) = pengiriman ulang tidak tercatat dua kali (NFR idempotensi).';

CREATE TABLE academics.teaching_attendance (
  id          uuid PRIMARY KEY,
  meeting_id  uuid NOT NULL REFERENCES delivery.meeting(id),
  centre_id   uuid NOT NULL REFERENCES identity.centre(id),
  staff_id    uuid NOT NULL REFERENCES identity.staff(person_id),
  role        text NOT NULL DEFAULT 'teacher' CHECK (role IN ('teacher','substitute')),
  recorded_by uuid NOT NULL REFERENCES identity.user_account(id),
  recorded_at timestamptz NOT NULL,
  device_id   uuid REFERENCES identity.device_registration(id),
  source      text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  UNIQUE (meeting_id, staff_id, role)
);
COMMENT ON TABLE academics.teaching_attendance IS 'DASAR TUNJANGAN ACTUAL TEACHING (rule #5). Berbeda dari presensi kerja (HRIS, rule #6). Diharamkan UPDATE/DELETE setelah cycle masuk period_lock — ditegakkan trigger guard (009). Export hanya dari cycle locked.';

-- ===== nilai harian =====
CREATE TABLE academics.daily_score (
  id            uuid PRIMARY KEY,
  meeting_id    uuid NOT NULL REFERENCES delivery.meeting(id),
  centre_id     uuid NOT NULL REFERENCES identity.centre(id),
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  score         score_scale NOT NULL,
  note          text,
  recorded_by   uuid NOT NULL REFERENCES identity.user_account(id),
  recorded_at   timestamptz NOT NULL,
  device_id     uuid REFERENCES identity.device_registration(id),
  source        text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  UNIQUE (meeting_id, enrollment_id)
);
COMMENT ON TABLE academics.daily_score IS 'Satu nilai 1-5 per pertemuan, dari pengamatan umum (tanpa komponen). rule #9: HANYA guru + teacher coordinator yang boleh baca — ditegakkan via role_grant/permission, bukan filter UI. Orang tua/siswa tidak pernah melihat ini.';

-- ===== IMPACT (perilaku) =====
CREATE TABLE academics.impact_value (
  id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code     text NOT NULL UNIQUE,
  name     text NOT NULL,
  order_no int NOT NULL UNIQUE,
  rubric_desc text
);
COMMENT ON TABLE academics.impact_value IS '6 nilai IMPACT. Seed di db/seed/program_config.sql.';

CREATE TABLE academics.impact_rating (
  id              uuid PRIMARY KEY,
  enrollment_id   uuid NOT NULL REFERENCES identity.enrollment(id),
  cycle_id        uuid NOT NULL REFERENCES delivery.cycle(id),
  impact_value_id uuid NOT NULL REFERENCES academics.impact_value(id),
  score           score_scale NOT NULL,
  recorded_by     uuid NOT NULL REFERENCES identity.user_account(id),
  recorded_at     timestamptz NOT NULL,
  source          text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  UNIQUE (enrollment_id, cycle_id, impact_value_id)
);
COMMENT ON TABLE academics.impact_rating IS 'Sekali per siklus per nilai, memakai rubrik.';

-- ===== ujian =====
CREATE TABLE academics.unit_test_result (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id  uuid NOT NULL REFERENCES identity.enrollment(id),
  centre_id      uuid NOT NULL REFERENCES identity.centre(id),
  level_id       uuid NOT NULL REFERENCES curriculum.curriculum_level(id),
  term_id        uuid NOT NULL REFERENCES curriculum.level_term(id),
  score          score_scale NOT NULL,
  below_readiness boolean NOT NULL,          -- score < readiness_min_score
  tested_at      date NOT NULL,
  recorded_by    uuid NOT NULL REFERENCES identity.user_account(id),
  UNIQUE (enrollment_id, term_id)
);
COMMENT ON TABLE academics.unit_test_result IS 'Batas kesiapan 3.0. below_readiness = PENANDA terbuka, tidak memblokir kenaikan (rule #10).';

CREATE TABLE academics.cambridge_mock_sitting (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id  uuid NOT NULL REFERENCES identity.program(id),
  name        text NOT NULL,
  mock_index  int NOT NULL,                  -- keberapa dalam siklus mock
  sitting_date date NOT NULL,
  UNIQUE (program_id, sitting_date)
);
CREATE TABLE academics.cambridge_mock_result (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sitting_id     uuid NOT NULL REFERENCES academics.cambridge_mock_sitting(id),
  enrollment_id  uuid NOT NULL REFERENCES identity.enrollment(id),
  score          score_scale,
  band           text,
  certificate_ref text,
  UNIQUE (sitting_id, enrollment_id)
);

-- ===== Montessori: catatan kualitatif harian =====
CREATE TABLE academics.montessori_observation (
  id            uuid PRIMARY KEY,
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  centre_id     uuid NOT NULL REFERENCES identity.centre(id),
  observed_on   date NOT NULL,
  staff_id      uuid NOT NULL REFERENCES identity.staff(person_id),
  note_text     text NOT NULL,
  source        text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  recorded_at   timestamptz NOT NULL
);
COMMENT ON TABLE academics.montessori_observation IS 'Penilaian Montessori sepenuhnya kualitatif, ditulis guru setiap hari. Tidak ada angka.';

-- ===== penempatan & kenaikan =====
CREATE TABLE academics.term_placement (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id     uuid NOT NULL REFERENCES identity.student(person_id),
  enrollment_id  uuid NOT NULL REFERENCES identity.enrollment(id),
  from_level_id  uuid REFERENCES curriculum.curriculum_level(id),
  from_term_id   uuid REFERENCES curriculum.level_term(id),
  to_level_id    uuid NOT NULL REFERENCES curriculum.curriculum_level(id),
  to_term_id     uuid NOT NULL REFERENCES curriculum.level_term(id),
  valid_from     date NOT NULL,
  reason         text NOT NULL CHECK (reason IN ('placement_test','promotion','early_promotion','demoted','schedule_change','re_entry')),
  decided_by     uuid REFERENCES identity.user_account(id),
  note           text,
  UNIQUE (enrollment_id, valid_from)
);
COMMENT ON TABLE academics.term_placement IS 'Riwayat penuh posisi level/term per enrollment. Menopang perpindahan kelompok (turun level, naik lebih awal, ganti jadwal).';

CREATE TABLE academics.promotion_event (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promotion_scope     text NOT NULL CHECK (promotion_scope IN ('section','enrollment')),
  section_id          uuid REFERENCES delivery.class_section(id),
  enrollment_id       uuid REFERENCES identity.enrollment(id),
  from_term_id        uuid NOT NULL REFERENCES curriculum.level_term(id),
  to_term_id          uuid NOT NULL REFERENCES curriculum.level_term(id),
  mode                text NOT NULL CHECK (mode IN ('automatic','teacher_decided')),
  decided_by          uuid REFERENCES identity.user_account(id),
  decided_at          timestamptz NOT NULL DEFAULT now(),
  below_readiness_flag boolean NOT NULL DEFAULT false,
  note_text           text,
  CHECK ((promotion_scope = 'section' AND section_id IS NOT NULL)
      OR (promotion_scope = 'enrollment' AND enrollment_id IS NOT NULL)),
  CHECK (below_readiness_flag = false OR (note_text IS NOT NULL AND btrim(note_text) <> ''))
);
COMMENT ON TABLE academics.promotion_event IS 'section = kenaikan kohort (5 program otomatis). enrollment = Calistung/Montessori, waktu ditentukan guru saat tahapan silabus selesai. TIDAK ADA constraint yang memblokir kenaikan; flag + catatan wajib bila di bawah batas dan ditampilkan terbuka (rule #10).';

CREATE TABLE academics.placement_test (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id        uuid NOT NULL REFERENCES identity.person(id),
  lead_id          uuid,   -- FK ke crm.crm_lead ditambahkan di 007
  centre_id        uuid NOT NULL REFERENCES identity.centre(id),
  speaking_score   numeric(4,2),
  written_score    numeric(4,2),
  result_level_id  uuid NOT NULL REFERENCES curriculum.curriculum_level(id),
  result_term_id   uuid NOT NULL REFERENCES curriculum.level_term(id),
  tested_at        timestamptz NOT NULL,
  tested_by        uuid REFERENCES identity.user_account(id)
);
COMMENT ON TABLE academics.placement_test IS 'Speaking + written test. Menentukan level & term awal siswa baru (3.3).';

CREATE TABLE academics.student_leave (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id  uuid NOT NULL REFERENCES identity.enrollment(id),
  start_date     date NOT NULL,
  end_date       date,
  reason_code    text,
  approved_by    uuid REFERENCES identity.user_account(id),
  CHECK (end_date IS NULL OR end_date >= start_date)
);
COMMENT ON TABLE academics.student_leave IS 'Bahan hitung Exam Discount Voucher (cuti > 1 bulan = reset periode) dan retensi siswa.';

-- ===== rapor =====
CREATE TABLE academics.report_card (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  centre_id     uuid NOT NULL REFERENCES identity.centre(id),
  level_id      uuid NOT NULL REFERENCES curriculum.curriculum_level(id),
  term_id       uuid NOT NULL REFERENCES curriculum.level_term(id),
  cycle_id      uuid REFERENCES delivery.cycle(id),
  status        text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published')),
  published_at  timestamptz,
  published_by  uuid REFERENCES identity.user_account(id),
  UNIQUE (enrollment_id, term_id)
);
CREATE TABLE academics.report_card_component (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_card_id  uuid NOT NULL REFERENCES academics.report_card(id),
  source          text NOT NULL CHECK (source IN ('attendance_summary','daily_avg','unit_test','impact','teacher_comment')),
  value_num       numeric(6,2),
  value_text      text,
  order_no        int NOT NULL DEFAULT 0
);
COMMENT ON TABLE academics.report_card_component IS 'daily_avg = agregat nilai harian yang boleh tampil di rapor; nilai harian mentah TETAP tidak diakses orang tua (rule #9).';

CREATE TABLE academics.report_card_release (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_card_id   uuid NOT NULL REFERENCES academics.report_card(id),
  recipient_user_id uuid NOT NULL REFERENCES identity.user_account(id),
  role_view        text NOT NULL CHECK (role_view IN ('student','guardian')),
  released_at      timestamptz NOT NULL DEFAULT now(),
  seen_at          timestamptz,
  UNIQUE (report_card_id, recipient_user_id, role_view)
);
COMMENT ON TABLE academics.report_card_release IS 'Gerbang visibilitas per penerima. release -> trigger kirim notifikasi WhatsApp "rapor terbit" (notification_log).';
