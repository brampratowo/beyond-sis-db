-- 007_crm.sql — D7: funnel Lead -> Guest -> Trial -> Registrasi, kanal akuisisi, CPA, alert, eskalasi WA
-- Menggantikan Google Sheets + Jotform. Kunci penghubung = nomor WhatsApp (contact_identifier), bukan kode ID.

CREATE TABLE crm.acquisition_channel (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name      text NOT NULL,
  type      text NOT NULL CHECK (type IN ('org_event','referral','social','ads','website','jotform_embed','word_of_mouth','walk_in','other')),
  is_active boolean NOT NULL DEFAULT true,
  UNIQUE (name, type)
);
COMMENT ON TABLE crm.acquisition_channel IS 'Setiap lead WAJIB mencatat kanal akuisisi -> dasar CPA & efektivitas kanal (3.6, Bagian 7).';

CREATE TABLE crm.channel_cost (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id   uuid REFERENCES identity.centre(id),   -- NULL = biaya kanal global/org
  channel_id  uuid NOT NULL REFERENCES crm.acquisition_channel(id),
  period      date NOT NULL CHECK (date_trunc('month', period) = period),  -- selalu tanggal 1
  amount      money NOT NULL,
  note        text
);
CREATE UNIQUE INDEX uq_channel_cost ON crm.channel_cost (centre_id, channel_id, period) NULLS NOT DISTINCT;
COMMENT ON TABLE crm.channel_cost IS 'CPA = sum(channel_cost.amount) / jumlah registrasi menang pada kanal & periode yang sama. Lihat v_cpa_by_channel (900).';

CREATE TABLE crm.crm_lead (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  centre_id               uuid NOT NULL REFERENCES identity.centre(id),
  contact_identifier_id   uuid REFERENCES identity.contact_identifier(id),  -- kunci WA
  person_id               uuid REFERENCES identity.person(id),              -- terisi setelah dikenal/di-registrasi
  channel_id              uuid NOT NULL REFERENCES crm.acquisition_channel(id), -- NOT NULL = wajib
  owner_staff_id          uuid REFERENCES identity.staff(person_id),
  source_ref              text,                       -- id Jotform / baris sheet saat migrasi
  status                  text NOT NULL DEFAULT 'new'
    CHECK (status IN ('new','contacted','guest','trial_scheduled','trialed','won','lost','expired','merged')),
  lost_reason             text,
  merged_into_lead_id     uuid REFERENCES crm.crm_lead(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz,
  CHECK (contact_identifier_id IS NOT NULL OR person_id IS NOT NULL)  -- minimal 1 pengenal
);
CREATE INDEX ix_lead_wa ON crm.crm_lead (contact_identifier_id);
CREATE INDEX ix_lead_status_centre ON crm.crm_lead (centre_id, status);
COMMENT ON TABLE crm.crm_lead IS 'Tahap funnel di-derive dari status + crm_stage_event. Empat tahap: Lead, Guest, Trial Class, Registrasi.';

CREATE TABLE crm.crm_stage_event (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id     uuid NOT NULL REFERENCES crm.crm_lead(id),
  from_stage  text,
  to_stage    text NOT NULL CHECK (to_stage IN ('lead','guest','trial','registration','lost')),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  recorded_by uuid REFERENCES identity.user_account(id)
);
COMMENT ON TABLE crm.crm_stage_event IS 'append-only. Sumber corong (funnel) per kanal di dasbor CRM. Tidak ada UPDATE/DELETE (guard 009).';

CREATE TABLE crm.crm_guest_visit (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id        uuid NOT NULL REFERENCES crm.crm_lead(id),
  visited_at     timestamptz NOT NULL,
  host_staff_id  uuid REFERENCES identity.staff(person_id),
  programme_interest jsonb,
  notes          text
);
CREATE TABLE crm.crm_trial_class (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id    uuid NOT NULL REFERENCES crm.crm_lead(id),
  section_id uuid REFERENCES delivery.class_section(id),
  trial_date date NOT NULL,
  outcome    text CHECK (outcome IN ('attended','no_show','converted')),
  feedback   text
);

CREATE TABLE crm.crm_registration (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id       uuid NOT NULL UNIQUE REFERENCES crm.crm_lead(id),
  student_id    uuid NOT NULL REFERENCES identity.student(person_id),
  enrollment_id uuid NOT NULL REFERENCES identity.enrollment(id),
  registered_at timestamptz NOT NULL DEFAULT now(),
  form_data     jsonb      -- snapshot formulir Jotform lama, untuk audit migrasi
);
COMMENT ON TABLE crm.crm_registration IS 'Saat lead jadi registrasi, SATU transaksi membuat person/student/enrollment -> data otomatis tersedia di SIS tanpa diketik ulang (rule 3.6). Enrollment_id di-isi di sini, dan status lead -> won + stage_event registration.';

CREATE TABLE crm.followup_task (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id     uuid NOT NULL REFERENCES crm.crm_lead(id),
  due_at      timestamptz NOT NULL,
  completed_at timestamptz,
  assigned_to uuid REFERENCES identity.staff(person_id),
  note        text
);
CREATE INDEX ix_followup_open ON crm.followup_task (due_at) WHERE completed_at IS NULL;

CREATE TABLE crm.alert_rule (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,   -- lead_unfollowed, lead_overdue, silent_exit, otp_breach, wf_breach, obs_quota_short
  params      jsonb NOT NULL DEFAULT '{}',
  target_role text NOT NULL
);
CREATE TABLE crm.alert (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id      uuid NOT NULL REFERENCES crm.alert_rule(id),
  centre_id    uuid REFERENCES identity.centre(id),
  lead_id      uuid REFERENCES crm.crm_lead(id),
  enrollment_id uuid REFERENCES identity.enrollment(id),
  raised_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,
  resolved_by  uuid REFERENCES identity.user_account(id),
  note         text
);
CREATE INDEX ix_alert_open ON crm.alert (centre_id, raised_at) WHERE resolved_at IS NULL;
COMMENT ON TABLE crm.alert IS 'Peringatan otomatis: lead belum ditindaklanjuti, lead lewat batas follow-up, siswa berhenti tanpa alasan (dari enrollment_exit.reason_code kosong).';

CREATE TABLE crm.whatsapp_escalation (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id           uuid REFERENCES crm.crm_lead(id),
  enrollment_id     uuid REFERENCES identity.enrollment(id),
  centre_id         uuid NOT NULL REFERENCES identity.centre(id),
  conversation_ref  text NOT NULL UNIQUE,   -- id percakapan Chatwoot
  summary           text,
  severity          text NOT NULL DEFAULT 'medium' CHECK (severity IN ('low','medium','high')),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','assigned','resolved')),
  assigned_staff_id uuid REFERENCES identity.staff(person_id),
  received_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz
);
COMMENT ON TABLE crm.whatsapp_escalation IS 'Eskalasi keluhan dari chatbot (Meta Cloud API + Chatwoot + n8n) -> diteruskan ke Portal Admin centre terkait (Bagian 10).';

CREATE TABLE crm.crm_kpi_snapshot (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period      date NOT NULL CHECK (date_trunc('month', period) = period),
  centre_id   uuid REFERENCES identity.centre(id),
  program_id  uuid REFERENCES identity.program(id),
  metrics     jsonb NOT NULL,   -- 8 indikator utama + funnel per kanal + CPA + retensi
  computed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period, centre_id, program_id)
);
COMMENT ON TABLE crm.crm_kpi_snapshot IS 'append-only snapshot dasbor CRM (recomputable, tidak pernah mengubah angka historis).';

-- lengkapi FK placement_test.lead_id
ALTER TABLE academics.placement_test
  ADD CONSTRAINT fk_placement_lead FOREIGN KEY (lead_id) REFERENCES crm.crm_lead(id);
