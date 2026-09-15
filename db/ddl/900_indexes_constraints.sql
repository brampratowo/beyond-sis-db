-- 900_indexes_constraints.sql — index pelindung, trigger audit/append-only/lock-guard, view laporan

-- ===== UNIQUE pelindung duplikat sync sudah inline di 005/008. Index pendukung query hot: =====
CREATE INDEX ix_attendance_enrollment ON academics.attendance (enrollment_id);  -- riwayat kehadiran siswa
CREATE INDEX ix_daily_score_enrol     ON academics.daily_score (enrollment_id, meeting_id);
CREATE INDEX ix_teach_att_staff       ON academics.teaching_attendance (staff_id);
CREATE INDEX ix_invoice_due_status    ON finance.invoice (due_date, status) WHERE status IN ('issued','partially_paid','overdue');
CREATE INDEX ix_lead_channel          ON crm.crm_lead (channel_id, status);
CREATE INDEX ix_membership_section    ON delivery.section_membership (section_id) WHERE valid_to IS NULL;

-- ===== trigger audit (NFR: nilai, presensi mengajar, transaksi keuangan) =====
CREATE TRIGGER trg_audit_daily_score   BEFORE UPDATE OR DELETE ON academics.daily_score
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_daily_score_i AFTER INSERT ON academics.daily_score
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_teach_att     BEFORE UPDATE OR DELETE ON academics.teaching_attendance
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_teach_att_i   AFTER INSERT ON academics.teaching_attendance
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_attendance    BEFORE UPDATE OR DELETE ON academics.attendance
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_cash          BEFORE UPDATE OR DELETE ON finance.cash_transaction
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_invoice       BEFORE UPDATE OR DELETE ON finance.invoice
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_payment       BEFORE UPDATE OR DELETE ON finance.payment
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();
CREATE TRIGGER trg_audit_mastery       BEFORE UPDATE OR DELETE ON montessori.material_mastery
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_audit();

-- ===== append-only guards =====
CREATE TRIGGER trg_ap_cycle_cfg  BEFORE UPDATE OR DELETE ON curriculum.program_cycle_config
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_assess_cfg BEFORE UPDATE OR DELETE ON curriculum.program_assessment_config
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_stage_evt  BEFORE UPDATE OR DELETE ON crm.crm_stage_event
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_term_place BEFORE DELETE ON academics.term_placement
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_promotion  BEFORE UPDATE OR DELETE ON academics.promotion_event
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_teach_assign BEFORE DELETE ON delivery.teacher_assignment
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_membership   BEFORE DELETE ON delivery.section_membership
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_period_lock  BEFORE DELETE ON platform.period_lock
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
CREATE TRIGGER trg_ap_sync_item    BEFORE DELETE ON platform.sync_item
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_append_only();
-- sync_item boleh UPDATE kolom hasil (applied_at/error_*) oleh worker; barisnya sendiri tidak boleh dihapus.
-- UPDATE konfigurasi boleh HANYA oleh super_admin -> tegakkan di lapisan aplikasi (SET ROLE rendah saat runtime).

-- ===== lock guards (rule #5, Q4) =====
CREATE TRIGGER trg_guard_teach_att BEFORE UPDATE OR DELETE ON academics.teaching_attendance
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_locked_meeting_guard();
CREATE TRIGGER trg_guard_attendance BEFORE UPDATE OR DELETE ON academics.attendance
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_locked_meeting_guard();
CREATE TRIGGER trg_guard_daily_score BEFORE UPDATE OR DELETE ON academics.daily_score
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_locked_meeting_guard();
CREATE TRIGGER trg_guard_cash BEFORE UPDATE OR DELETE ON finance.cash_transaction
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_locked_cycle_guard();
CREATE TRIGGER trg_guard_invoice BEFORE UPDATE OR DELETE ON finance.invoice
  FOR EACH ROW EXECUTE FUNCTION platform.ifx_locked_cycle_guard();

-- ===== view laporan =====

-- CPA per kanal per bulan = biaya kanal / lead yang menjadi registrasi
CREATE OR REPLACE VIEW finance.v_cpa_by_channel AS
WITH won AS (
  SELECT date_trunc('month', r.registered_at) AS period, l.channel_id, l.centre_id,
         count(*) AS registrations
  FROM   crm.crm_registration r
  JOIN   crm.crm_lead l ON l.id = r.lead_id
  GROUP  BY 1, 2, 3
)
SELECT w.period, ch.name AS channel, c.name AS centre, w.registrations,
       cc.amount AS channel_cost,
       round(cc.amount / NULLIF(w.registrations, 0), 0) AS cpa
FROM   won w
JOIN   crm.acquisition_channel ch ON ch.id = w.channel_id
LEFT   JOIN identity.centre c ON c.id = w.centre_id
LEFT   JOIN crm.channel_cost cc
       ON cc.channel_id = w.channel_id AND cc.period = w.period
      AND cc.centre_id IS NOT DISTINCT FROM w.centre_id;

-- OTP & WF kini per centre/program (vs snapshot historis)
CREATE OR REPLACE VIEW finance.v_otp_wf_live AS
SELECT date_trunc('month', i.due_date) AS period, i.centre_id, i.program_id,
       count(*) FILTER (WHERE p.paid_on_time)                            AS on_time,
       count(*) FILTER (WHERE i.status IN ('overdue'))                   AS waiting_fund,
       count(*)                                                          AS total_billable,
       round(100.0 * count(*) FILTER (WHERE p.paid_on_time) / NULLIF(count(*),0), 2) AS otp_pct,
       round(100.0 * count(*) FILTER (WHERE i.status = 'overdue')  / NULLIF(count(*),0), 2) AS wf_pct
FROM   finance.invoice i
LEFT   JOIN LATERAL (
         SELECT bool_or(pay.paid_at <= i.due_date) AS paid_on_time
         FROM   finance.payment pay WHERE pay.invoice_id = i.id
       ) p ON true
WHERE  i.status <> 'void'
GROUP  BY 1, 2, 3;

-- dasar Tunjangan Actual Teaching — hanya baris pada cycle yang sedang LOCKED
CREATE OR REPLACE VIEW finance.v_teaching_allowance AS
SELECT ta.staff_id, cy.section_id, s.centre_id, cy.academic_month_id,
       count(*) FILTER (WHERE ta.role = 'teacher')    AS meetings_taught,
       count(*) FILTER (WHERE ta.role = 'substitute') AS meetings_substitute
FROM   academics.teaching_attendance ta
JOIN   delivery.meeting m   ON m.id = ta.meeting_id
JOIN   delivery.cycle cy    ON cy.id = m.cycle_id
JOIN   delivery.class_section s ON s.id = cy.section_id
WHERE  EXISTS (SELECT 1 FROM platform.period_lock pl
               WHERE pl.cycle_id = cy.id AND pl.lock_type = 'teaching_attendance'
                 AND pl.locked_at IS NOT NULL AND pl.unlocked_at IS NULL)
GROUP  BY 1, 2, 3, 4;
COMMENT ON VIEW finance.v_teaching_allowance IS 'Uang hanya boleh diekspor dari sini: sumber = periode LOCKED (rule #5).';

-- kuota observasi: minimal 2 per guru per siklus
CREATE OR REPLACE VIEW quality.v_observation_quota AS
SELECT cy.id AS cycle_id, ta.staff_id AS teacher_id,
       count(o.id) AS observations,
       count(o.id) >= 2 AS quota_met
FROM   delivery.cycle cy
JOIN   delivery.teacher_assignment ta ON ta.section_id = cy.section_id
       AND ta.role = 'teacher'
       AND ta.valid_from <= cy.opened_at
       AND (ta.valid_to IS NULL OR ta.valid_to >= cy.opened_at)
LEFT   JOIN quality.teaching_observation o ON o.teacher_id = ta.staff_id AND o.cycle_id = cy.id
GROUP  BY 1, 2;

-- retensi per kohort per periode
CREATE OR REPLACE VIEW crm.v_retention AS
SELECT date_trunc('month', e.enrolled_at) AS period, e.teaching_centre_id AS centre_id, e.program_id,
       count(*) AS enrolled,
       count(*) FILTER (WHERE e.status = 'active')     AS still_active,
       count(*) FILTER (WHERE e.status = 'dropped_out') AS dropped,
       count(*) FILTER (WHERE ex.reason_code IS NULL AND ex.id IS NOT NULL) AS dropped_without_reason
FROM   identity.enrollment e
LEFT   JOIN identity.enrollment_exit ex ON ex.enrollment_id = e.id
GROUP  BY 1, 2, 3;

-- laba rugi & arus kas per program/centre per bulan
CREATE OR REPLACE VIEW finance.v_pnl AS
SELECT date_trunc('month', g.occurred_on) AS period, g.centre_id, g.program_id,
       sum(g.credit - g.debit) FILTER (WHERE g.account LIKE 'revenue%') AS revenue,
       sum(g.debit - g.credit) FILTER (WHERE g.account LIKE 'expense%') AS expense,
       sum(g.debit - g.credit) FILTER (WHERE g.account = 'cash')        AS cash_inflow
FROM   finance.gl_entry g
GROUP  BY 1, 2, 3;
