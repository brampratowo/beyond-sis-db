-- 008_finance.sql — D8: kas, invoice otomatis, payment gateway, rekonsiliasi, voucher, OTP/WF, buku besar minimal

CREATE TABLE finance.cash_category (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id  uuid REFERENCES identity.centre(id),  -- NULL = template global
  name       text NOT NULL,
  direction  text NOT NULL CHECK (direction IN ('in','out')),
  is_system  boolean NOT NULL DEFAULT false,
  is_active  boolean NOT NULL DEFAULT true,
  UNIQUE (centre_id, direction, name)
);
COMMENT ON TABLE finance.cash_category IS 'Kategori kas configurable per centre (Bagian 8).';

CREATE TABLE finance.invoice_series (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id  uuid REFERENCES identity.program(id),
  centre_id   uuid REFERENCES identity.centre(id),
  study_mode  text NOT NULL CHECK (study_mode IN ('formal','non_formal')),
  prefix      text NOT NULL,
  next_no     bigint NOT NULL DEFAULT 1,          -- generator server-side
  UNIQUE (program_id, centre_id, study_mode)
);
COMMENT ON TABLE finance.invoice_series IS 'Nomor invoice TIDAK pernah dari klien (aman terhadap baris luring yang tiba terlambat). Diambil atomic dari next_no (SELECT ... FOR UPDATE).';

CREATE TABLE finance.cash_transaction (
  id           uuid PRIMARY KEY,                    -- boleh dibuat offline
  centre_id    uuid NOT NULL REFERENCES identity.centre(id),
  occurred_on  date NOT NULL,
  category_id  uuid NOT NULL REFERENCES finance.cash_category(id),
  direction    text NOT NULL CHECK (direction IN ('in','out')),
  amount       money NOT NULL,
  method       text NOT NULL CHECK (method IN ('cash','transfer','ewallet','qris','other')),
  ref_no       text,
  description  text,
  cycle_id     uuid REFERENCES delivery.cycle(id),
  recorded_by  uuid NOT NULL REFERENCES identity.user_account(id),
  device_id    uuid REFERENCES identity.device_registration(id),
  reversed_at  timestamptz,
  reversal_of_id uuid REFERENCES finance.cash_transaction(id),
  source       text NOT NULL DEFAULT 'online' CHECK (source IN ('online','offline_sync')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_cash_centre_date ON finance.cash_transaction (centre_id, occurred_on);
COMMENT ON TABLE finance.cash_transaction IS 'Kas harian per centre. Koreksi = baris reversal (bukan delete/update) -> audit utuh. Setelah periode locked: UPDATE/DELETE ditolak (guard 009).';

CREATE TABLE finance.invoice (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_no     text NOT NULL UNIQUE,
  enrollment_id  uuid NOT NULL REFERENCES identity.enrollment(id),
  centre_id      uuid NOT NULL REFERENCES identity.centre(id),
  program_id     uuid NOT NULL REFERENCES identity.program(id),
  cycle_id       uuid NOT NULL REFERENCES delivery.cycle(id),
  study_mode     text NOT NULL CHECK (study_mode IN ('formal','non_formal')),
  issue_date     date NOT NULL,
  due_date       date NOT NULL,
  amount         money NOT NULL,
  status         text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','issued','partially_paid','paid','overdue','void')),
  voided_at      timestamptz,
  void_reason    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (enrollment_id, cycle_id)   -- 1 pendaftaran 1 invoice per siklus = anti-dobel tagih saat re-run
);
CREATE INDEX ix_invoice_centre_status ON finance.invoice (centre_id, status, due_date);
COMMENT ON TABLE finance.invoice IS 'Diterbitkan otomatis bulanan dari enrollment aktif (Formal & Non-Formal). Status paid/partial/overdue = turunan dari pembayaran; kolom status materialized untuk pantau langsung (masalah #4).';

CREATE TABLE finance.invoice_line (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id  uuid NOT NULL REFERENCES finance.invoice(id),
  description text NOT NULL,
  amount      money NOT NULL,
  order_no    int NOT NULL DEFAULT 0
);

CREATE TABLE finance.voucher_rule (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  min_continuous_months int NOT NULL,
  max_leave_months      int NOT NULL,
  amount                money NOT NULL,
  effective_from        date NOT NULL,
  UNIQUE (min_continuous_months, max_leave_months, effective_from)
);
CREATE TABLE finance.exam_discount_voucher (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id             uuid NOT NULL REFERENCES identity.student(person_id),
  rule_id                uuid NOT NULL REFERENCES finance.voucher_rule(id),
  qualifying_window_from date NOT NULL,
  qualifying_window_to   date NOT NULL,
  amount                 money NOT NULL,
  status                 text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','used','expired','void')),
  issued_at              timestamptz NOT NULL DEFAULT now(),
  used_invoice_id        uuid REFERENCES finance.invoice(id),
  used_at                timestamptz
);
COMMENT ON TABLE finance.exam_discount_voucher IS 'Aturan 3.7: 12 bln tanpa putus cuti = Rp1.200.000; 12 bln cuti <=1 bln = Rp600.000; cuti >1 bln RESET (tidak memenuhi syarat -> tidak ada baris). Jendela dihitung dari student_leave + enrollment continuity.';

CREATE TABLE finance.gateway_config (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider     text NOT NULL CHECK (provider IN ('midtrans','xendit')),
  mode         text NOT NULL CHECK (mode IN ('sandbox','production')),
  purpose      text NOT NULL CHECK (purpose IN ('collection','disbursement')),
  api_keys_ref text NOT NULL,   -- path secret/vault, BUKAN nilai secret
  is_active    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE finance.gateway_config IS 'Xendit = pencairan dana (disbursement) yang sudah jalan. Gateway baru = collection dukung transfer bank, e-wallet, QRIS. Kredensial Midtrans disediakan BEYOND. Secret disimpan di vault/env, DB hanya pointer.';

CREATE TABLE finance.gateway_transaction (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider         text NOT NULL CHECK (provider IN ('midtrans','xendit')),
  ext_ref          text NOT NULL,
  idempotency_key  text NOT NULL UNIQUE,
  invoice_id       uuid REFERENCES finance.invoice(id),
  centre_id        uuid REFERENCES identity.centre(id),
  amount           money NOT NULL,
  currency         text NOT NULL DEFAULT 'IDR',
  channel          text CHECK (channel IN ('bank_transfer','ewallet','qris','card','other')),
  status           text NOT NULL CHECK (status IN ('pending','settled','failed','refunded','expired')),
  raw              jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  settled_at       timestamptz,
  UNIQUE (provider, ext_ref)
);
COMMENT ON TABLE finance.gateway_transaction IS 'Webhook -> upsert by (provider, ext_ref) / idempotency_key. Duplicate webhook aman (UNIQUE).';

CREATE TABLE finance.payment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id       uuid NOT NULL REFERENCES identity.centre(id),
  student_id      uuid REFERENCES identity.student(person_id),
  invoice_id      uuid REFERENCES finance.invoice(id),
  amount          money NOT NULL,
  method          text NOT NULL CHECK (method IN ('transfer','ewallet','qris','cash','gateway','voucher')),
  gateway_txn_id  uuid REFERENCES finance.gateway_transaction(id),
  voucher_id      uuid REFERENCES finance.exam_discount_voucher(id),
  paid_at         timestamptz NOT NULL,
  confirmed_by    uuid REFERENCES identity.user_account(id),
  reversed_at     timestamptz,
  UNIQUE (gateway_txn_id)   -- 1 transaksi gateway max 1 payment
);
CREATE INDEX ix_payment_invoice ON finance.payment (invoice_id);
COMMENT ON TABLE finance.payment IS 'Pembayaran bisa manual (kas/tunai) atau dari gateway. invoice_id NULL = deposit/unapplied, di-apply belakangan.';

CREATE TABLE finance.payment_reconciliation (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gateway_txn_id  uuid NOT NULL UNIQUE REFERENCES finance.gateway_transaction(id),
  payment_id      uuid NOT NULL REFERENCES finance.payment(id),
  matched_by      text NOT NULL CHECK (matched_by IN ('auto','manual')),
  matched_at      timestamptz NOT NULL DEFAULT now(),
  matched_by_user uuid REFERENCES identity.user_account(id),
  variance        numeric(14,2) DEFAULT 0
);
COMMENT ON TABLE finance.payment_reconciliation IS 'Pencocokan otomatis invoice<->pembayaran: VA/QRIS payload + nominal + ref invoice. Tidak ketemu -> variance & antre rekonsiliasi manual (runbook).';

CREATE TABLE finance.finance_target (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id  uuid REFERENCES identity.centre(id),   -- NULL = default org
  program_id uuid REFERENCES identity.program(id),
  period     date NOT NULL CHECK (date_trunc('month', period) = period),
  otp_min    numeric(5,2) NOT NULL DEFAULT 85.00,   -- On-Time Payment minimal (%)
  wf_max     numeric(5,2) NOT NULL DEFAULT 0.40,    -- Waiting Fund maksimal (%)
  UNIQUE (centre_id, program_id, period)
);
CREATE TABLE finance.otp_wf_snapshot (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period             date NOT NULL CHECK (date_trunc('month', period) = period),
  centre_id          uuid NOT NULL REFERENCES identity.centre(id),
  program_id         uuid NOT NULL REFERENCES identity.program(id),
  otp_pct            numeric(5,2),
  wf_pct             numeric(5,2),
  on_time_count      int,
  waiting_fund_count int,
  total_billable     int,
  computed_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period, centre_id, program_id)
);
COMMENT ON TABLE finance.otp_wf_snapshot IS 'Dihitung otomatis bulanan, per program & per centre, append-only (angka historis tak berubah saat recompute). Dibandingkan vs finance_target -> alert breach (otp_breach/wf_breach).';

CREATE TABLE finance.invoice_reminder_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id        uuid NOT NULL REFERENCES finance.invoice(id),
  sent_at           timestamptz NOT NULL DEFAULT now(),
  channel           text NOT NULL DEFAULT 'whatsapp',
  template_code     text NOT NULL,
  external_msg_id   text,
  recipient_user_id uuid REFERENCES identity.user_account(id)
);
COMMENT ON TABLE finance.invoice_reminder_log IS 'Pengingat jatuh tempo otomatis via WhatsApp H-x (x dari system_config). Satu invoice bisa diingatkan beberapa kali.';

-- Buku besar minimal untuk arus kas + laba rugi per program & per centre
CREATE TABLE finance.gl_entry (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_on  date NOT NULL,
  centre_id    uuid NOT NULL REFERENCES identity.centre(id),
  program_id   uuid REFERENCES identity.program(id),
  account      text NOT NULL,   -- cash, revenue_spp, revenue_material, revenue_exam, discount_voucher, expense_*
  debit        money NOT NULL DEFAULT 0,
  credit       money NOT NULL DEFAULT 0,
  source_type  text NOT NULL CHECK (source_type IN ('cash_txn','invoice','payment','voucher','adjustment')),
  source_id    uuid,
  is_adjustment boolean NOT NULL DEFAULT false,
  adjustment_reason text,
  posted_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (debit > 0 OR credit > 0),
  CHECK (is_adjustment = false OR (adjustment_reason IS NOT NULL AND btrim(adjustment_reason) <> ''))
);
CREATE INDEX ix_gl_period ON finance.gl_entry (occurred_on, centre_id, program_id);
COMMENT ON TABLE finance.gl_entry IS 'Jurnal dari transaksi bisnis (auto-posted). Entri manual hanya bila is_adjustment + alasan wajib. Menopang laporan bulanan: arus kas, laba rugi per program, laba rugi per centre.';
