-- 006_quality_montessori.sql — D5 mutu pengajaran + D6 kerangka Montessori user-definable

-- ===== D5 =====
CREATE TABLE quality.coordinator_assignment (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coordinator_id uuid NOT NULL REFERENCES identity.staff(person_id),
  teacher_id     uuid NOT NULL REFERENCES identity.staff(person_id),
  valid_from     date NOT NULL DEFAULT current_date,
  valid_to       date,
  CHECK (coordinator_id <> teacher_id),
  EXCLUDE USING gist (teacher_id WITH =, daterange(valid_from, valid_to) WITH &&)
);
COMMENT ON TABLE quality.coordinator_assignment IS '1 Teacher Coordinator membawahi 5-8 guru. Batas dicek aplikasi (assert) karena 1 guru hanya 1 coordinator aktif (EXCLUDE).';

CREATE TABLE quality.observation_rubric (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version        int NOT NULL,
  dimension_code text NOT NULL,
  name           text NOT NULL,
  weight         numeric(4,2) NOT NULL DEFAULT 1.00,
  max_score      score_scale NOT NULL DEFAULT 5.00,
  UNIQUE (version, dimension_code)
);

CREATE TABLE quality.teaching_observation (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  teacher_id   uuid NOT NULL REFERENCES identity.staff(person_id),
  section_id   uuid REFERENCES delivery.class_section(id),
  cycle_id     uuid REFERENCES delivery.cycle(id),
  meeting_id   uuid REFERENCES delivery.meeting(id),
  observer_id  uuid NOT NULL REFERENCES identity.staff(person_id),   -- teacher coordinator
  score        score_scale NOT NULL,
  rubric_id    uuid REFERENCES quality.observation_rubric(id),
  findings     jsonb,                                                -- detail per dimensi rubrik
  followup_note text,
  observed_at  timestamptz NOT NULL
);
CREATE INDEX ix_obs_teacher_cycle ON quality.teaching_observation (teacher_id, cycle_id);
COMMENT ON TABLE quality.teaching_observation IS 'Minimal 2 observasi/bulan/guru. Kuota dihitung di view v_observation_quota (lihat 900).';

CREATE TABLE quality.tdi_snapshot (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id       uuid NOT NULL REFERENCES identity.staff(person_id),
  cycle_id       uuid NOT NULL REFERENCES delivery.cycle(id),
  components     jsonb NOT NULL,     -- {observation_avg, attendance_rate, retention, score_summary}
  composite_score numeric(5,2),
  computed_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staff_id, cycle_id)
);
COMMENT ON TABLE quality.tdi_snapshot IS 'Teacher Development Index. 1 baris per staff per cycle. Re-compute = UPDATE baris yang sama SELAMA cycle belum locked; setelah locked, snapshot beku (trigger guard 009).';

CREATE TABLE quality.monthly_quality_review (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id        uuid NOT NULL REFERENCES identity.centre(id),
  program_id       uuid REFERENCES identity.program(id),
  cycle_id         uuid REFERENCES delivery.cycle(id),
  coordinator_id   uuid NOT NULL REFERENCES identity.staff(person_id),
  attendance_metric jsonb,
  retention_metric  jsonb,
  score_summary     jsonb,
  notes            text,
  reviewed_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (coordinator_id, cycle_id, program_id)
);
COMMENT ON TABLE quality.monthly_quality_review IS 'Evaluasi bulanan coordinator: kehadiran siswa, retensi, ringkasan nilai (3.5).';

-- ===== D6 Montessori (kerangka dibuat/dihapus oleh akademik Montessori) =====
CREATE TABLE montessori.montessori_curriculum (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id   uuid REFERENCES identity.centre(id),   -- NULL = berlaku global
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  is_archived boolean NOT NULL DEFAULT false,
  archived_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE montessori.montessori_subject (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  curriculum_id  uuid NOT NULL REFERENCES montessori.montessori_curriculum(id),
  code           text NOT NULL,
  name           text NOT NULL,
  order_no       int NOT NULL DEFAULT 0,
  is_archived    boolean NOT NULL DEFAULT false,
  archived_at    timestamptz,
  UNIQUE (curriculum_id, code)
);
CREATE TABLE montessori.montessori_material (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id   uuid NOT NULL REFERENCES montessori.montessori_subject(id),
  code         text NOT NULL,
  name         text NOT NULL,
  description  text,
  order_no     int NOT NULL DEFAULT 0,
  age_band     text,
  is_archived  boolean NOT NULL DEFAULT false,
  archived_at  timestamptz,
  UNIQUE (subject_id, code)
);
CREATE TABLE montessori.material_mastery (
  id                 uuid PRIMARY KEY,               -- boleh dibuat offline
  enrollment_id      uuid NOT NULL REFERENCES identity.enrollment(id),
  material_id        uuid NOT NULL REFERENCES montessori.montessori_material(id),
  status             text NOT NULL CHECK (status IN ('presented','practiced','mastered')),
  first_presented_at timestamptz,
  updated_by         uuid REFERENCES identity.user_account(id),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  source             text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  UNIQUE (enrollment_id, material_id)
);
CREATE TABLE montessori.material_mastery_log (
  id          uuid PRIMARY KEY,
  mastery_id  uuid NOT NULL REFERENCES montessori.material_mastery(id),
  from_status text CHECK (from_status IN ('presented','practiced','mastered')),
  to_status   text NOT NULL CHECK (to_status IN ('presented','practiced','mastered')),
  changed_by  uuid REFERENCES identity.user_account(id),
  changed_at  timestamptz NOT NULL,
  source      text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync'))
);
COMMENT ON TABLE montessori.montessori_curriculum IS
  'Curriculum -> Subject -> Material, ditambahkan/dihapus pihak akademik Montessori (SIS khusus). Semua level soft-archive (is_archived), TIDAK ada hard delete -> riwayat penguasaan siswa tidak pernah rusak. Mastery log append-only.';
