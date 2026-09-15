-- 002_curriculum.sql — D2: level/term tangga kurikulum + konfigurasi program VERSI (bukan nilai tetap)
-- Aturan utama: tidak ada UPDATE pada baris konfigurasi lama. Perubahan = INSERT baris baru dengan effective_from.

CREATE TABLE curriculum.syllabus_stage (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id uuid NOT NULL REFERENCES identity.program(id),
  code       text NOT NULL,
  name       text NOT NULL,
  order_no   int  NOT NULL,
  UNIQUE (program_id, code),
  UNIQUE (program_id, order_no)
);
COMMENT ON TABLE curriculum.syllabus_stage IS 'Tahapan silabus. Untuk Calistung/Montessori: kenaikan term terjadi saat stage selesai, bukan per kalender.';

CREATE TABLE curriculum.curriculum_level (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id uuid NOT NULL REFERENCES identity.program(id),
  level_no   int  NOT NULL,
  name       text NOT NULL,          -- mis. "Kids 1", "Key 2"
  is_active  boolean NOT NULL DEFAULT true,
  UNIQUE (program_id, level_no)
);
CREATE TABLE curriculum.level_term (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  level_id          uuid NOT NULL REFERENCES curriculum.curriculum_level(id),
  term_no           int  NOT NULL,
  name              text NOT NULL,    -- "Term 1" .. "Term 12"
  syllabus_stage_id uuid REFERENCES curriculum.syllabus_stage(id),
  UNIQUE (level_id, term_no)
);
COMMENT ON TABLE curriculum.level_term IS '1 term = 1 bulan akademik (satuan KURIKULUM). Bukan satuan penagihan — lihat delivery.cycle.';

-- ===== konfigurasi berversi (rule #3) =====
CREATE TABLE curriculum.program_cycle_config (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id         uuid NOT NULL REFERENCES identity.program(id),
  effective_from     date NOT NULL,
  meetings_per_cycle smallint NOT NULL CHECK (meetings_per_cycle > 0),
  classes_per_year   smallint CHECK (classes_per_year > 0),
  note               text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid REFERENCES identity.user_account(id),
  UNIQUE (program_id, effective_from)
);
COMMENT ON TABLE curriculum.program_cycle_config IS
  'Satuan PENGIRIMAN & PENAGIHAN. Peralihan 10 -> 8 meeting Jan-2027: INSERT (program, ''2027-01-01'', 8, 96, ''peralihan silabus''). Baris 2025-01-01/10 tetap apa adanya. UPDATE/DELETE ditolak trigger (lihat 009).';

CREATE TABLE curriculum.program_assessment_config (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id             uuid NOT NULL REFERENCES identity.program(id),
  effective_from         date NOT NULL,
  daily_score_scale      text NOT NULL DEFAULT '1-5',
  unit_test_frequency    text NOT NULL CHECK (unit_test_frequency IN ('per_term','per_2_terms','at_stage_completion','none')),
  mock_interval_terms    int,                                   -- NULL = tidak ada Cambridge Mock
  promotion_mode         text NOT NULL CHECK (promotion_mode IN ('automatic','teacher_decided')),
  readiness_min_score    numeric(3,2) DEFAULT 3.00,             -- NULL = tidak berlaku (Montessori, tanpa angka)
  montessori_framework   boolean NOT NULL DEFAULT false,        -- true => pakai kerangka D6, penilaian kualitatif
  note                   text,
  UNIQUE (program_id, effective_from)
);
COMMENT ON TABLE curriculum.program_assessment_config IS 'Matriks Bagian 5. Readiness 3.0 = PENANDA, bukan pemblokir kenaikan (rule #10).';

-- lengkapi FK enrollment -> curriculum
ALTER TABLE identity.enrollment
  ADD CONSTRAINT fk_enroll_level FOREIGN KEY (level_id) REFERENCES curriculum.curriculum_level(id),
  ADD CONSTRAINT fk_enroll_term  FOREIGN KEY (term_id)  REFERENCES curriculum.level_term(id);
