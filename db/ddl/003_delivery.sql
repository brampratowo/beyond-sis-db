-- 003_delivery.sql — D3: dua kalender, kohort, siklus, meeting, penugasan guru
-- rule #2: academic_month (kurikulum) != calendar month (keuangan). rule #4: kohort tahan lama, penugasan guru berversi.

CREATE TABLE delivery.academic_year (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  year      int NOT NULL UNIQUE,
  starts_on date NOT NULL,
  ends_on   date NOT NULL
);
CREATE TABLE delivery.academic_month (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  year_id   uuid NOT NULL REFERENCES delivery.academic_year(id),
  seq_no    int  NOT NULL CHECK (seq_no BETWEEN 1 AND 12),
  name      text NOT NULL,
  starts_on date NOT NULL,
  ends_on   date NOT NULL,
  UNIQUE (year_id, seq_no),
  EXCLUDE USING gist (daterange(starts_on, ends_on + 1) WITH &&)  -- bulan akademik tidak boleh tumpang tindih
);
COMMENT ON TABLE delivery.academic_month IS 'Bulan akademik; bisa menyeberang bulan kalender (rule: dua penanggalan jalan terpisah). 1 academic_month = 1 term untuk delivery.';

CREATE TABLE delivery.calendar_holiday (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  holiday_date date NOT NULL UNIQUE,
  name        text NOT NULL,
  is_national boolean NOT NULL DEFAULT true
);

CREATE TABLE delivery.class_section (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  program_id  uuid NOT NULL REFERENCES identity.program(id),
  centre_id   uuid NOT NULL REFERENCES identity.centre(id),
  name        text NOT NULL,
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','merged','closed')),
  formed_on   date NOT NULL DEFAULT current_date,
  closed_on   date
);
COMMENT ON TABLE delivery.class_section IS 'KOHORT. Kelompok siswa tetap sama dari bulan ke bulan walau guru berganti (rule #4). Ukuran ideal 13.';

CREATE TABLE delivery.section_membership (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id    uuid NOT NULL REFERENCES delivery.class_section(id),
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  valid_from    date NOT NULL,
  valid_to      date,
  reason_code   text NOT NULL CHECK (reason_code IN ('enrolled','demoted','early_promotion','schedule_change','merged_in','split_out')),
  UNIQUE (enrollment_id, valid_from),
  EXCLUDE USING gist (enrollment_id WITH =, daterange(valid_from, valid_to) WITH &&)  -- 1 enrollment di 1 section pada satu waktu
);
COMMENT ON TABLE delivery.section_membership IS 'Riwayat keanggotaan kohort: pindah kelompok krna turun level / naik lebih awal / ganti jadwal.';

CREATE TABLE delivery.class_section_merge (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_section_id  uuid NOT NULL REFERENCES delivery.class_section(id),
  source_section_id  uuid NOT NULL REFERENCES delivery.class_section(id),
  merged_on          date NOT NULL,
  note               text,
  CHECK (target_section_id <> source_section_id)
);
COMMENT ON TABLE delivery.class_section_merge IS 'Jejak penggabungan kelas saat jumlah siswa berkurang. source -> status merged.';

CREATE TABLE delivery.schedule_slot (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id   uuid NOT NULL REFERENCES delivery.class_section(id),
  day_of_week  smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Min .. 6=Sat
  group_code   text NOT NULL CHECK (group_code IN ('A','B','FRIDAY_ROTATION')),
  start_time   time NOT NULL,
  room         text,
  effective_from date NOT NULL,
  effective_to   date
);
COMMENT ON TABLE delivery.schedule_slot IS 'Grup A = Senin(1)+Rabu(3); Grup B = Selasa(2)+Kamis(4); Jumat(5) bergantian utk capai 10 meeting; Sabtu(6) = hari penggantian (makeup).';

CREATE TABLE delivery.cycle (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id        uuid NOT NULL REFERENCES delivery.class_section(id),
  academic_month_id uuid NOT NULL REFERENCES delivery.academic_month(id),
  config_id         uuid NOT NULL REFERENCES curriculum.program_cycle_config(id),  -- SNAPSHOT
  meetings_planned  smallint NOT NULL,        -- disalin dari config saat siklus dibuka
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','locked','closed')),
  opened_by         uuid REFERENCES identity.user_account(id),
  opened_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (section_id, academic_month_id)
);
COMMENT ON TABLE delivery.cycle IS 'SATUAN PENGIRIMAN + PENAGIHAN: 1 section x 1 bulan akademik. meetings_planned di-snapshot dari config_id, jadi laporan lama tidak berubah saat config baru masuk (rule #3).';

CREATE TABLE delivery.meeting (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_id                  uuid NOT NULL REFERENCES delivery.cycle(id),
  seq_no                    smallint NOT NULL,
  scheduled_date            date NOT NULL,
  slot_id                   uuid REFERENCES delivery.schedule_slot(id),
  group_code                text CHECK (group_code IN ('A','B','FRIDAY_ROTATION')),
  is_makeup                 boolean NOT NULL DEFAULT false,
  makeup_for_meeting_id     uuid REFERENCES delivery.meeting(id),
  deferred_from_meeting_id  uuid REFERENCES delivery.meeting(id),
  holiday_id                uuid REFERENCES delivery.calendar_holiday(id),
  status                    text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','held','cancelled')),
  held_on                   date,
  UNIQUE (cycle_id, seq_no)
);
CREATE INDEX ix_meeting_date ON delivery.meeting (scheduled_date);
COMMENT ON TABLE delivery.meeting IS 'Generator siklus menulis baris final. Jumat kena libur nasional -> baris tetap dihitung + deferred_from_meeting_id menunjuk Jumat berikutnya. Kurang meeting -> baris Sabtu dengan is_makeup=true.';

CREATE TABLE delivery.teacher_assignment (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id  uuid NOT NULL REFERENCES delivery.class_section(id),
  staff_id    uuid NOT NULL REFERENCES identity.staff(person_id),
  role        text NOT NULL CHECK (role IN ('teacher','substitute','coordinator_observing')),
  valid_from  date NOT NULL,
  valid_to    date,
  assigned_by uuid REFERENCES identity.user_account(id),
  note        text,
  EXCLUDE USING gist (section_id WITH =, staff_id WITH =, daterange(valid_from, valid_to) WITH &&)
);
COMMENT ON TABLE delivery.teacher_assignment IS 'Penugasan guru berversi waktu -> riwayat "guru mengajar kelas apa kapan" pulih (masalah #2 dokumen). role=substitute utk kasus digantikan (rule #6). 1 guru >=3 kelas/hari dicek di view.';

-- lengkapi FK enrollment.entry_cycle_id
ALTER TABLE identity.enrollment
  ADD CONSTRAINT fk_enroll_entry_cycle FOREIGN KEY (entry_cycle_id) REFERENCES delivery.cycle(id);
