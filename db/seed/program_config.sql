-- seed/program_config.sql — data awal konfigurasi (matriks Bagian 5 dokumen)
-- Idempoten-ish: jalankan sekali pada DB kosong. UUID statis agar relasi antar-baris mudah dibaca.

BEGIN;

-- 7 centre
INSERT INTO identity.centre (id, code, name, is_hq) VALUES
 ('11111111-0000-0000-0000-000000000001','ENTROP','Entrop (HQ)', true),
 ('11111111-0000-0000-0000-000000000002','PDBLN','Padang Bulan', false),
 ('11111111-0000-0000-0000-000000000003','PMHLT','PMA Holtekamp', false),
 ('11111111-0000-0000-0000-000000000004','SNPOS7','Sentani Pos 7', false),
 ('11111111-0000-0000-0000-000000000005','SNROKIM','Sentani Rokim', false),
 ('11111111-0000-0000-0000-000000000006','SKK10','Sorong Kilo', false),
 ('11111111-0000-0000-0000-000000000007','SKKAMP','Sorong Kampung Baru', false);

-- 7 program (kode matriks Bagian 5; study_mode: Formal = program berjenjang ber-invoice bulanan formal)
INSERT INTO identity.program (id, code, name, study_mode) VALUES
 ('22222222-0000-0000-0000-000000000001','KidsEnglish','KidsEnglish (Cambridge English)','formal'),
 ('22222222-0000-0000-0000-000000000002','TeensEnglish','TeensEnglish (General/Cambridge)','formal'),
 ('22222222-0000-0000-0000-000000000003','SpeakNow','SpeakNow','non_formal'),
 ('22222222-0000-0000-0000-000000000004','CambridgeMaths','Cambridge Maths','formal'),
 ('22222222-0000-0000-0000-000000000005','BimbelMatSD','Bimbel Matematika SD','non_formal'),
 ('22222222-0000-0000-0000-000000000006','Calistung','Calistung','non_formal'),
 ('22222222-0000-0000-0000-000000000007','MontessoriAcademy','Papua Montessori Academy','non_formal');

-- program_cycle_config: versi AWAL = 10 meeting/siklus (Fase 1). classes_per_year = 120.
INSERT INTO curriculum.program_cycle_config (program_id, effective_from, meetings_per_cycle, classes_per_year, note)
SELECT p.id, DATE '2025-01-01', 10, 120, 'konfigurasi awal Fase 1' FROM identity.program p;

-- >>> Peralihan Januari 2027 (JAWABAN Q2): satu-satunya aksi = INSERT baris baru di bawah,
-- >>> dieksekusi saat go-live 2027. Baris lama tidak disentuh; laporan lama baca snapshot cycle.
-- INSERT INTO curriculum.program_cycle_config (program_id, effective_from, meetings_per_cycle, classes_per_year, note)
-- SELECT p.id, DATE '2027-01-01', 8, 96, 'peralihan silabus internal: 8 pertemuan per siklus'
-- FROM identity.program p;

-- program_assessment_config = matriks Bagian 5
INSERT INTO curriculum.program_assessment_config
(program_id, effective_from, unit_test_frequency, mock_interval_terms, promotion_mode, readiness_min_score, montessori_framework, note) VALUES
 ('22222222-0000-0000-0000-000000000001','2025-01-01','per_term',         4,   'automatic',       3.00, false, 'KidsEnglish: unit test tiap term, mock tiap 4 term'),
 ('22222222-0000-0000-0000-000000000002','2025-01-01','per_term',         6,   'automatic',       3.00, false, 'TeensEnglish: mock tiap 6 term'),
 ('22222222-0000-0000-0000-000000000003','2025-01-01','per_term',      NULL,   'automatic',       3.00, false, 'SpeakNow: writing tiap term; presentasi tiap 2 term (di model via custom field)'),
 ('22222222-0000-0000-0000-000000000004','2025-01-01','per_term',      NULL,   'automatic',       3.00, false, 'Cambridge Maths'),
 ('22222222-0000-0000-0000-000000000005','2025-01-01','per_term',      NULL,   'automatic',       3.00, false, 'Bimbel Mat SD'),
 ('22222222-0000-0000-0000-000000000006','2025-01-01','at_stage_completion', NULL, 'teacher_decided', 3.00, false, 'Calistung: kenaikan saat tahapan selesai (2-4 bulan), guru + koordinator'),
 ('22222222-0000-0000-0000-000000000007','2025-01-01','none',          NULL,   'teacher_decided', NULL, true,  'Montessori Academy: tanpa level/term tetap, tanpa unit test, penilaian kualitatif harian');

-- tangga level & term
INSERT INTO curriculum.curriculum_level (id, program_id, level_no, name) VALUES
 ('33333333-0000-0000-0000-000000000011','22222222-0000-0000-0000-000000000001',1,'Kids Level 1'),
 ('33333333-0000-0000-0000-000000000012','22222222-0000-0000-0000-000000000001',2,'Kids Level 2'),
 ('33333333-0000-0000-0000-000000000013','22222222-0000-0000-0000-000000000001',3,'Kids Level 3'),
 ('33333333-0000-0000-0000-000000000014','22222222-0000-0000-0000-000000000001',4,'Kids Level 4'),
 ('33333333-0000-0000-0000-000000000015','22222222-0000-0000-0000-000000000001',5,'Kids Level 5'),
 ('33333333-0000-0000-0000-000000000021','22222222-0000-0000-0000-000000000002',1,'Teens Level 1'),
 ('33333333-0000-0000-0000-000000000022','22222222-0000-0000-0000-000000000002',2,'Teens Level 2');
-- TODO tim DB+akademik: lengkapi level Teens 3-8, SpeakNow 1-4, Maths 1-6, Bimbel 1-6, Calistung 1-4 (name & urutan disepakati)

-- term per level: 12 term utk Kids/Maths/Bimbel, 6 utk Teens, 2 utk SpeakNow/Calistung (contoh Kids Level 1)
INSERT INTO curriculum.level_term (level_id, term_no, name)
SELECT l.id, gs, 'Term ' || gs
FROM   curriculum.curriculum_level l
JOIN   identity.program p ON p.id = l.program_id
CROSS  JOIN LATERAL (SELECT generate_series(1, CASE p.code
                        WHEN 'KidsEnglish' THEN 12 WHEN 'TeensEnglish' THEN 6
                        WHEN 'SpeakNow' THEN 2 WHEN 'CambridgeMaths' THEN 12
                        WHEN 'BimbelMatSD' THEN 12 WHEN 'Calistung' THEN 2 END) AS gs) gs;

-- 6 nilai IMPACT (kode nama dikonfirmasi tim akademik — placeholder)
INSERT INTO academics.impact_value (code, name, order_no) VALUES
 ('I','Initiative',1),('M','Motivation',2),('P','Persistence',3),
 ('A','Accountability',4),('C','Collaboration',5),('T','Thinking',6);

-- voucher rule (3.7)
INSERT INTO finance.voucher_rule (min_continuous_months, max_leave_months, amount, effective_from) VALUES
 (12, 0, 1200000, '2025-01-01'),   -- 12 bulan tanpa putus cuti
 (12, 1,  600000, '2025-01-01');   -- 12 bulan, cuti maksimal 1 bulan
-- cuti > 1 bulan: tidak ada baris = tidak memenuhi syarat (reset periode)

-- kategori kas standar (bisa ditambah/diarsipkan per centre)
INSERT INTO finance.cash_category (centre_id, name, direction) VALUES
 (NULL,'SPP / invoice',        'in'),
 (NULL,'Biaya ujian',          'in'),
 (NULL,'Denda / lain-lain',    'in'),
 (NULL,'Gaji & tunjangan',     'out'),
 (NULL,'Sewa & utilitas',      'out'),
 (NULL,'Materi & perlengkapan','out'),
 (NULL,'Marketing / kanal',    'out');

-- kanal akuisisi standar
INSERT INTO crm.acquisition_channel (name, type) VALUES
 ('Event sekolah','org_event'),('Referral wali','referral'),('Instagram','social'),
 ('Facebook Ads','ads'),('Website my.beyond.sch.id','website'),('Datang langsung','walk_in'),
 ('Mulut ke mulut','word_of_mouth');

-- roles
INSERT INTO identity.role (code, name) VALUES
 ('student','Siswa'),('guardian','Orang Tua'),('teacher','Guru'),
 ('teacher_coordinator','Teacher Coordinator'),('education_consultant','Education Consultant'),
 ('finance_coordinator','Finance Coordinator'),('centre_admin','Admin Centre'),('super_admin','Super Admin');

-- alert rules
INSERT INTO crm.alert_rule (code, params, target_role) VALUES
 ('lead_unfollowed','{"within_hours": 24}',   'education_consultant'),
 ('lead_overdue',   '{"overdue_days": 3}',    'education_consultant'),
 ('silent_exit',    '{}',                     'centre_admin'),
 ('otp_breach',     '{"min_pct": 85}',        'finance_coordinator'),
 ('wf_breach',      '{"max_pct": 0.4}',       'finance_coordinator'),
 ('obs_quota_short','{"min_per_month": 2}',   'teacher_coordinator');

-- system config dasar
INSERT INTO platform.system_config (key, scope, value) VALUES
 ('reminder_lead_days','global','{"days": [3, 1]}'),
 ('readiness_flag_display','global','{"public_to_guardian": true}');  -- rule #10: tanda di rapor tampil terbuka

COMMIT;
