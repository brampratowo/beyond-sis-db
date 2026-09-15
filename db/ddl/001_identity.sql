-- 001_identity.sql — D1: centre, program, person, student, guardian, staff, access, device, moodle link
-- Keputusan: person = manusia unik; student/guardian/staff = subtype; enrollment = "pendaftaran" (satuan tagihan & laporan per centre).

CREATE TABLE identity.centre (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  is_hq       boolean NOT NULL DEFAULT false,
  address     text,
  phone       text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz
);
COMMENT ON TABLE identity.centre IS '7 centre BEYOND. Entrop = HQ. Semua tabel transaksi menyimpan centre_id untuk row-level scoping.';

CREATE TABLE identity.program (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  study_mode  text NOT NULL CHECK (study_mode IN ('formal','non_formal')),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE identity.program IS '7 program (Cambridge English, General English, Cambridge Maths, Bimbel Mat SD, Calistung, Montessori Playschool, Papua Montessori Academy). study_mode menentukan penerbitan invoice Formal/Non-Formal.';

CREATE TABLE identity.centre_program (
  centre_id   uuid REFERENCES identity.centre(id),
  program_id  uuid REFERENCES identity.program(id),
  is_active   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (centre_id, program_id)
);

CREATE TABLE identity.person (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name      text NOT NULL,
  gender         text CHECK (gender IN ('M','F','other')),
  birth_date     date,
  place_of_birth text,
  npwp           text,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz
);
COMMENT ON TABLE identity.person IS 'Satu baris = satu manusia unik. Jumlah siswa organisasi dihitung dari sini (via student).';

CREATE TABLE identity.contact_identifier (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id        uuid NOT NULL REFERENCES identity.person(id),
  channel          text NOT NULL CHECK (channel IN ('whatsapp','email','phone')),
  value_raw        text NOT NULL,
  value_normalized text NOT NULL,
  is_verified      boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, value_normalized)
);
COMMENT ON TABLE identity.contact_identifier IS 'value_normalized = E.164 untuk whatsapp. Nomor WA = kunci penghubung funnel CRM (lead->registrasi), bukan kode ID. UNIQUE(channel,value_normalized) = index lookup wajib CRM.';

CREATE TABLE identity.student (
  person_id    uuid PRIMARY KEY REFERENCES identity.person(id),
  student_code text NOT NULL UNIQUE,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE identity.student IS 'Person yang pernah/sedang terdaftar. count(*) = jumlah siswa ORG (orang unik). count(enrollment) = jumlah siswa per centre.';

CREATE TABLE identity.guardian (
  person_id  uuid PRIMARY KEY REFERENCES identity.person(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE identity.guardian_student (
  guardian_id     uuid REFERENCES identity.guardian(person_id),
  student_id      uuid REFERENCES identity.student(person_id),
  relationship    text NOT NULL CHECK (relationship IN ('ayah','ibu','wali','kakak','lain')),
  is_primary      boolean NOT NULL DEFAULT false,
  can_view_billing boolean NOT NULL DEFAULT true,
  PRIMARY KEY (guardian_id, student_id)
);
CREATE UNIQUE INDEX uq_guardian_primary ON identity.guardian_student (student_id) WHERE is_primary;

CREATE TABLE identity.staff (
  person_id        uuid PRIMARY KEY REFERENCES identity.person(id),
  staff_code       text NOT NULL UNIQUE,
  home_centre_id   uuid REFERENCES identity.centre(id),
  hire_date        date,
  employment_status text NOT NULL DEFAULT 'active' CHECK (employment_status IN ('active','inactive','alumni')),
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE identity.staff IS '±115 staf akademik & administrasi. Presensi KERJA tidak ada di sistem ini (HRIS) — lihat rule #6.';

CREATE TABLE identity.staff_position (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id   uuid NOT NULL REFERENCES identity.staff(person_id),
  position   text NOT NULL CHECK (position IN ('teacher','teacher_coordinator','education_consultant','finance_coordinator','centre_admin','super_admin','other')),
  centre_id  uuid REFERENCES identity.centre(id),
  valid_from date NOT NULL,
  valid_to   date,
  EXCLUDE USING gist (staff_id WITH =, daterange(valid_from, valid_to) WITH &&)
);
COMMENT ON TABLE identity.staff_position IS 'Riwayat posisi berversi waktu (append-only via EXCLUDE overlap).';

CREATE TABLE identity.enrollment (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id         uuid NOT NULL REFERENCES identity.student(person_id),
  program_id         uuid NOT NULL REFERENCES identity.program(id),
  teaching_centre_id uuid NOT NULL REFERENCES identity.centre(id),
  billing_centre_id  uuid NOT NULL REFERENCES identity.centre(id),
  study_mode         text NOT NULL CHECK (study_mode IN ('formal','non_formal')),
  entry_cycle_id     uuid,   -- FK ke delivery.cycle ditambahkan di 003
  level_id           uuid,   -- FK ke curriculum.curriculum_level di 002
  term_id            uuid,   -- FK ke curriculum.level_term di 002
  status             text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','on_leave','graduated','dropped_out','transferred')),
  enrolled_at        timestamptz NOT NULL DEFAULT now(),
  ended_at           timestamptz,
  exit_reason_code   text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz
);
CREATE INDEX ix_enrollment_student ON identity.enrollment (student_id);
CREATE INDEX ix_enrollment_centre_status ON identity.enrollment (teaching_centre_id, status);
COMMENT ON TABLE identity.enrollment IS 'PENDAFTARAN = (student x program x centre x periode). 1 siswa bisa >1 enrollment simultan, beda centre pun boleh. Satuan invoice & laporan per centre. active-only count = "jumlah siswa per centre".';

CREATE TABLE identity.user_account (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id     uuid UNIQUE REFERENCES identity.person(id),
  username      text NOT NULL UNIQUE,
  password_hash text,
  mfa_secret    text,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  last_login_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz
);
CREATE TABLE identity.role (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,  -- student, guardian, teacher, teacher_coordinator, education_consultant, finance_coordinator, centre_admin, super_admin
  name text NOT NULL
);
CREATE TABLE identity.permission (
  id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,  -- score.daily.view/write, attendance.write, invoice.issue, ...
  name text NOT NULL
);
CREATE TABLE identity.role_permission (
  role_id       uuid REFERENCES identity.role(id),
  permission_id uuid REFERENCES identity.permission(id),
  PRIMARY KEY (role_id, permission_id)
);
CREATE TABLE identity.role_grant (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES identity.user_account(id),
  role_id    uuid NOT NULL REFERENCES identity.role(id),
  centre_id  uuid REFERENCES identity.centre(id),  -- NULL = scope global (Super Admin)
  valid_from date NOT NULL DEFAULT current_date,
  valid_to   date,
  UNIQUE (user_id, role_id, centre_id)
);
COMMENT ON TABLE identity.role_grant IS 'Akses operasional dibatasi per centre (centre_id terisi). Super Admin = centre_id NULL. Guru: scope tambahan = hanya kelas ditugaskan (view v_teacher_section).';

CREATE TABLE identity.device_registration (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES identity.user_account(id),
  device_token      text NOT NULL UNIQUE,
  platform          text NOT NULL CHECK (platform IN ('android','ios','web','laptop')),
  registered_at     timestamptz NOT NULL DEFAULT now(),
  revoked_at        timestamptz,
  revocation_reason text,
  wipe_requested_at timestamptz,
  wiped_at          timestamptz,
  UNIQUE (user_id, device_token)
);
COMMENT ON TABLE identity.device_registration IS 'Cabut akses -> set revoked_at + wipe_requested_at; dieksekusi klien pada sync berikutnya, lalu wiped_at diisi (NFR keamanan perangkat).';

CREATE TABLE identity.moodle_user_link (
  user_id         uuid PRIMARY KEY REFERENCES identity.user_account(id),
  moodle_user_id  bigint UNIQUE,
  moodle_username text,
  last_synced_at  timestamptz,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ok','failed','revoked'))
);

-- diletak di sini karena user_account FK dibutuhkan
CREATE TABLE identity.enrollment_exit (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  exited_at     timestamptz NOT NULL DEFAULT now(),
  reason_code   text,          -- NULL/empty => memicu alert silent_exit (CRM)
  notes         text,
  recorded_by   uuid REFERENCES identity.user_account(id)
);
