-- 009_platform.sql — D9: audit, periode terkunci, sync luring idempoten, integrasi, konfigurasi

-- ===== AUDIT =====
CREATE TABLE platform.audit_log (
  id            bigint GENERATED ALWAYS AS IDENTITY,
  table_name    text NOT NULL,
  row_id        uuid NOT NULL,
  action        text NOT NULL CHECK (action IN ('insert','update','delete')),
  before        jsonb,
  after         jsonb,
  actor_user_id uuid,
  actor_device_id uuid,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  source        text NOT NULL DEFAULT 'ui' CHECK (source IN ('ui','offline_sync','system','import')),
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
COMMENT ON TABLE platform.audit_log IS 'Nilai, presensi mengajar, transaksi keuangan, invoice, payment: WAJIB tercatat before/after/aktor/waktu/perangkat (NFR jejak audit). Partition bulanan; retensi >= 360 hari mengikuti cadangan.';

CREATE TABLE platform.audit_log_202601 PARTITION OF platform.audit_log FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE platform.audit_log_default PARTITION OF platform.audit_log DEFAULT;
-- generator partition berikutnya: cron bulanan platform.ensure_audit_partition()
CREATE FUNCTION platform.ensure_audit_partition() RETURNS void AS $$
DECLARE nxt text := to_char(date_trunc('month', now()) + interval '2 month', 'YYYYMM');
        frm text := to_char(date_trunc('month', now()) + interval '1 month', 'YYYY-MM-01');
        to_ text := to_char(date_trunc('month', now()) + interval '2 month', 'YYYY-MM-01');
BEGIN
  EXECUTE format('CREATE TABLE IF NOT EXISTS platform.audit_log_%s PARTITION OF platform.audit_log FOR VALUES FROM (%L) TO (%L)', nxt, frm, to_);
END $$ LANGUAGE plpgsql;

CREATE FUNCTION platform.ifx_audit() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO platform.audit_log(table_name,row_id,action,before,after,actor_user_id,actor_device_id,source)
    VALUES (TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME, OLD.id, 'delete', to_jsonb(OLD), NULL,
            current_setting('app.user_id', true)::uuid, current_setting('app.device_id', true)::uuid,
            coalesce(current_setting('app.source', true), 'ui'));
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO platform.audit_log(table_name,row_id,action,before,after,actor_user_id,actor_device_id,source)
    VALUES (TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME, NEW.id, 'update', to_jsonb(OLD), to_jsonb(NEW),
            current_setting('app.user_id', true)::uuid, current_setting('app.device_id', true)::uuid,
            coalesce(current_setting('app.source', true), 'ui'));
    RETURN NEW;
  ELSE
    INSERT INTO platform.audit_log(table_name,row_id,action,before,after,actor_user_id,actor_device_id,source)
    VALUES (TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME, NEW.id, 'insert', NULL, to_jsonb(NEW),
            current_setting('app.user_id', true)::uuid, current_setting('app.device_id', true)::uuid,
            coalesce(current_setting('app.source', true), 'ui'));
    RETURN NEW;
  END IF;
END $$ LANGUAGE plpgsql;
COMMENT ON FUNCTION platform.ifx_audit IS 'Aplikasi SET app.user_id / app.device_id / app.source per transaksi. Pasang trigger ini pada: academics.daily_score, academics.teaching_attendance, academics.attendance, finance.cash_transaction, finance.invoice, finance.payment, montessori.material_mastery (contoh terlampir di 900).';

-- ===== PERIODE TERKUNCI (rule #5) =====
CREATE TABLE platform.period_lock (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lock_type     text NOT NULL CHECK (lock_type IN ('teaching_attendance','cycle','invoice_run','report_card_run')),
  centre_id     uuid NOT NULL REFERENCES identity.centre(id),
  program_id    uuid REFERENCES identity.program(id),
  cycle_id      uuid REFERENCES delivery.cycle(id),
  locked_by     uuid NOT NULL REFERENCES identity.user_account(id),
  locked_at     timestamptz NOT NULL DEFAULT now(),
  unlocked_by   uuid,
  unlocked_at   timestamptz,
  unlock_reason text,
  relocked_at   timestamptz
);
COMMENT ON TABLE platform.period_lock IS 'append-only: baris = kejadian lock; unlock = kolom unlock terisi + alasan WAJIB; re-lock = baris baru. Export tunjangan hanya boleh membaca data dari cycle yang sedang berstatus locked (tidak unlock aktif).';

CREATE TABLE platform.unlock_request (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lock_id      uuid NOT NULL REFERENCES platform.period_lock(id),
  reason       text NOT NULL,
  requested_by uuid NOT NULL REFERENCES identity.user_account(id),
  approved_by  uuid REFERENCES identity.user_account(id),
  approved_at  timestamptz,
  CHECK (approved_by IS NULL OR approved_by <> requested_by)  -- four-eyes: peminta ≠ pemberi izin
);
COMMENT ON TABLE platform.unlock_request IS 'Perubahan post-lock HANYA lewat jalur ini (Q4: mencegah/mendeteksi/menelusuri). Tanpa approval -> guard trigger menolak write.';

-- guard: tolak UPDATE/DELETE pada baris berversi-waktu/konfigurasi & data periode terkunci
CREATE FUNCTION platform.ifx_append_only() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '%: tabel konfigurasi/append-only tidak menerima %', TG_TABLE_NAME, TG_OP;
END $$ LANGUAGE plpgsql;
-- pasang (di 900) pada: curriculum.program_cycle_config, curriculum.program_assessment_config,
--   crm.crm_stage_event, finance.otp_wf_snapshot? (TIDAK — snapshot upsert per periode; lihat catatan),
--   platform.period_lock (hanya DELETE yang dilarang; UPDATE kolom unlock legal), delivery.teacher_assignment (delete dilarang).

CREATE FUNCTION platform.ifx_locked_cycle_guard() RETURNS trigger AS $$
-- utk tabel yang punya kolom cycle_id sendiri (cash_transaction, invoice)
DECLARE is_locked boolean;
DECLARE cid uuid := COALESCE(NEW.cycle_id, OLD.cycle_id);
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM platform.period_lock pl
    WHERE  pl.lock_type IN ('teaching_attendance','cycle')
      AND  pl.cycle_id = cid
      AND  pl.locked_at IS NOT NULL AND pl.unlocked_at IS NULL
  ) INTO is_locked;
  IF is_locked THEN
    RAISE EXCEPTION 'Periode terkunci: % pada %.% ditolak (butuh unlock_request disetujui)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

CREATE FUNCTION platform.ifx_locked_meeting_guard() RETURNS trigger AS $$
-- utk tabel berafkir meeting (attendance, daily_score, teaching_attendance)
DECLARE is_locked boolean;
DECLARE mid uuid := COALESCE(NEW.meeting_id, OLD.meeting_id);
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM platform.period_lock pl
    JOIN   delivery.meeting m ON m.cycle_id = pl.cycle_id
    WHERE  m.id = mid
      AND  pl.lock_type IN ('teaching_attendance','cycle')
      AND  pl.locked_at IS NOT NULL AND pl.unlocked_at IS NULL
  ) INTO is_locked;
  IF is_locked THEN
    RAISE EXCEPTION 'Periode terkunci: % pada %.% ditolak (butuh unlock_request disetujui)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;
-- pasang: meeting-guard pada academics.teaching_attendance/attendance/daily_score;
--        cycle-guard pada finance.cash_transaction, finance.invoice.

-- ===== SYNC LURING (rule #7) =====
CREATE TABLE platform.sync_batch (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES identity.user_account(id),
  device_id     uuid NOT NULL REFERENCES identity.device_registration(id),
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  item_count    int NOT NULL DEFAULT 0,
  applied_count int NOT NULL DEFAULT 0,
  rejected_count int NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','partial'))
);
CREATE TABLE platform.sync_item (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id     uuid NOT NULL REFERENCES platform.sync_batch(id),
  client_op_id text NOT NULL UNIQUE,        -- idempotensi: retry batch lama = no-op
  entity       text NOT NULL,
  row_id       uuid NOT NULL,               -- PK uuid dari klien
  op           text NOT NULL CHECK (op IN ('insert','update')),
  payload      jsonb NOT NULL,
  base_version int,
  applied_at   timestamptz,
  error_code   text,                        -- DUPLICATE_IGNORED, LOCKED_PERIOD, VERSION_CONFLICT, REQUIRES_REVIEW
  error_note   text
);
COMMENT ON TABLE platform.sync_item IS 'Setiap item apply dalam 1 transaksi server; client_op_id UNIQUE = pengiriman dua kali tidak tercatat dua kali. Gagal krn periode terkunci -> error LOCKED_PERIOD + antre pending_review (bukan hilang).';

CREATE TABLE platform.row_version (
  entity     text NOT NULL,
  row_id     uuid NOT NULL,
  version    bigint NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entity, row_id)
);
COMMENT ON TABLE platform.row_version IS 'Optimistic concurrency untuk update luring (base_version vs version kini -> VERSION_CONFLICT).';

CREATE TABLE platform.pending_review (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sync_item_id uuid NOT NULL REFERENCES platform.sync_item(id),
  reason      text NOT NULL,
  raised_at   timestamptz NOT NULL DEFAULT now(),
  resolved_by uuid REFERENCES identity.user_account(id),
  resolved_at timestamptz,
  resolution  text CHECK (resolution IN ('applied','discarded','re_recorded'))
);
COMMENT ON TABLE platform.pending_review IS 'Antrian tinjau manusia utk data luring yang tiba setelah periode terkunci (jawaban Q3/Q4).';

-- ===== INTEGRASI =====
CREATE TABLE platform.moodle_sync_state (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type    text NOT NULL CHECK (entity_type IN ('user','course','course_enrollment','teacher_enrollment')),
  entity_id      uuid NOT NULL,              -- id sisi SIS
  moodle_id      bigint,
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ok','failed','revoked')),
  last_synced_at timestamptz,
  error_note     text,
  retry_count    int NOT NULL DEFAULT 0,
  UNIQUE (entity_type, entity_id)
);
COMMENT ON TABLE platform.moodle_sync_state IS 'Provisioning otomatis: enrollment+penempatan section -> akun & course enrollment Moodle; teacher_assignment -> akses editing course. Revoke akses siswa -> status revoked + job hapus/pause enroll Moodle + revoke sso_session.';

CREATE TABLE platform.sso_session (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES identity.user_account(id),
  token_hash     text NOT NULL UNIQUE,
  issued_at      timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  revoked_at     timestamptz,
  revoked_reason text
);
COMMENT ON TABLE platform.sso_session IS 'Token SSO portal->Moodle (short-lived, auto-redirect login sekali jalan). Pencabutan: akses siswa dicabut -> revoke aktif di sini + role_grant valid_to + moodle_sync_state revoked.';

CREATE TABLE platform.notification_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel           text NOT NULL CHECK (channel IN ('whatsapp','email','push')),
  template_code     text NOT NULL,
  recipient_user_id uuid REFERENCES identity.user_account(id),
  subject_table     text,
  subject_id        uuid,
  external_msg_id   text,
  sent_at           timestamptz NOT NULL DEFAULT now(),
  status            text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent','failed','bounced')),
  error             text
);
COMMENT ON TABLE platform.notification_log IS 'Dorong via Meta Cloud API/Chatwoot/n8n: rapor terbit, kelas pengganti, pengingat jatuh tempo (Bagian 10).';

-- ===== MIGRASI & KONFIG =====
CREATE TABLE platform.import_batch (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source       text NOT NULL CHECK (source IN ('google_sheets','jotform','csv')),
  file_ref     text NOT NULL,
  rows_total   int,
  rows_ok      int,
  rows_failed  int,
  error_report jsonb,
  imported_by  uuid REFERENCES identity.user_account(id),
  imported_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE platform.import_batch IS 'Data awal siswa & pendaftaran aktif dari spreadsheet BEYOND (Bagian 15). Setiap baris hasil import menandai source_ref/audit source=import.';

CREATE TABLE platform.system_config (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key        text NOT NULL,
  scope      text NOT NULL DEFAULT 'global' CHECK (scope IN ('global','centre')),
  centre_id  uuid REFERENCES identity.centre(id),
  value      jsonb NOT NULL,
  updated_by uuid REFERENCES identity.user_account(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (key, scope, centre_id),
  CHECK ((scope = 'centre') = (centre_id IS NOT NULL))
);
COMMENT ON TABLE platform.system_config IS 'Mis. reminder_lead_days=3, alert thresholds, template WA. Super Admin yang mengubah (portal konfigurasi).';

CREATE TABLE platform.sequence_counter (
  name     text PRIMARY KEY,
  next_val bigint NOT NULL DEFAULT 1
);
COMMENT ON TABLE platform.sequence_counter IS 'Nomor invoice/label server-side, atomik: UPDATE ... SET next_val = next_val + 1 RETURNING next_val.';
