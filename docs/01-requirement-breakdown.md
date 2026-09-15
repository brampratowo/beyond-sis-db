# 01 — Requirement Breakdown
Sumber: *Vendor Brief SISTEM INFORMASI TERPADU BEYOND* (SIS + LMS + CRM + KEUANGAN), BEYOND Education Centre.
Track: **Database / data model**. Dokumen ini memecah seluruh kebutuhan menjadi butir yang dapat ditelusuri ke skema.

---

## 1. Identitas pekerjaan

| Field | Isi | Implikasi DB |
|---|---|---|
| Pemberi kerja | BEYOND Education Centre | — |
| Portal utama | `my.beyond.sch.id` (PWA) | app utama, DB Postgres |
| LMS | `lms.beyond.sch.id` (Moodle, subdomain terpisah) | DB Moodle MySQL/MariaDB terpisah, terhubung via link + SSO |
| Jenis pekerjaan | Aplikasi web PWA + mode luring modul guru; setup & integrasi Moodle | skema harus mendukung sync client-generated rows |
| Kontak teknis | Wesley Baan (Head of Organization Development) | penentu role Super Admin |

## 2. Pengguna & skala

- ±115 staf akademik & administrasi, ±1.300 siswa aktif, ±1.200 wali.
- 5 portal: Siswa, Orang Tua, Guru, Admin centre, Super Admin.
- Volume bulanan: ±15.000 baris kehadiran & nilai, ±1.500 invoice, ±1.500 pendaftaran kumulatif.
- Skala tulis: ±15.000 baris bisnis/bulan → kalikan audit_log (before/after) → ±90.000–120.000 baris/bulan. Retensi cadangan 360 hari → ±1,4 juta baris transaksi/bulan efektif. Kecil untuk Postgres; rancang untuk 10× tanpa re-shard (index + partitioning path disiapkan).

## 3. Masalah yang harus dipecahkan (Bagian 1)

Empat bagian jalan terpisah: data akademik di Google Sheets; lead/guest/trial/registrasi di Google Sheets + Jotform; keuangan di spreadsheet + Kledo; latihan mandiri di Cambridge One & OxfordLearn (tidak terhubung).

Kerusakan nyata yang jadi target desain:
1. Angka jumlah siswa berbeda antar divisi → **butuh satu sumber kebenaran + dua definisi hitung (pendaftaran vs orang unik)**.
2. Riwayat perpindahan guru antar kelas tidak tercatat rapi → **butuh tabel penugasan berversi waktu (append-only)**.
3. Kehadiran mengajar tidak terhubung ke perhitungan tunjangan → **butuh `teaching_attendance` sebagai dasar bayar + lock + audit**.
4. Status pembayaran siswa sulit dipantau langsung → **butuh status invoice materialized: lunas / menunggak (WF) / sebagian**.

## 4. Lingkup: 4 modul (Bagian 2.1)

| Modul | Isi | Rincian dokumen | Domain skema |
|---|---|---|---|
| SIS | siswa, kelas, jadwal, kehadiran, nilai, rapor, mutu pengajaran | Bagian 3–5 | D2–D6 |
| SIS khusus Montessori | kerangka user-definable `Curriculum → Subject → Material`; status penguasaan `Presented / Practiced / Mastered` | Bagian 2.1 | D6 |
| LMS | Moodle, subdomain terpisah, SSO dari portal | Bagian 6 | D9 (link) |
| CRM | lead → guest → trial → registrasi, komunikasi, keluhan via WhatsApp | Bagian 7 | D7 |
| Keuangan | kas masuk/keluar, invoice, payment gateway, akuntansi dasar | Bagian 8 | D8 |

## 5. Lima portal & hak akses (Bagian 2.2)

| Portal | Isi utama | Scope akses |
|---|---|---|
| Siswa | jadwal, kehadiran, nilai & rapor, hasil ujian, akses materi Moodle | per-enrollment miliknya |
| Orang Tua | semua isi Siswa untuk anaknya + tagihan, riwayat bayar, unduh invoice | per `guardian_student` |
| Guru | input kehadiran & nilai harian (mobile, luring), jadwal mengajar, hasil observasi & TDI, materi Moodle | **hanya kelas yang ditugaskan** |
| Admin centre | Education Consultant, Teacher Coordinator, Finance Coordinator: pendaftaran, kelas, kas & invoice centre, CRM centre | **per centre** |
| Super Admin | Organization Development + Managing Director: semua centre, laporan gabungan, konfigurasi sistem, hak akses | global |

Implikasi DB: semua tabel transaksi wajib menyimpan `centre_id` agar row-level scoping tidak perlu join; `role_grant` mendukung `centre_id NULL` = scope global.

## 6. Fakta operasional yang membentuk data (Bagian 3)

### 6.1 Organisasi & program
- 7 centre: Entrop (HQ), Padang Bulan, PMA Holtekamp, Sentani Pos 7, Sentani Rokim, Sorong Kilo, Sorong Kampung Baru.
- 7 program: Cambridge English, General English, Cambridge Maths, Bimbel Matematika SD, Calistung, Montessori Playschool, Papua Montessori Academy.
- Satu centre menjalankan sebagian program → relasi `centre_program`.
- 1 siswa bisa ikut >1 program bersamaan, dan program-program itu bisa di centre berbeda → **enrollment = (student, program, centre, periode)**.
- Kelas ideal 13 siswa; jumlah turun → kelas digabung → perlu `class_section_merge` (riwayat, bukan overwrite).
- 1 guru mengajar minimal 3 kelas/hari.

### 6.2 Siklus penyampaian
- 10 meeting per bulan akademik, 120 per tahun.
- **Bulan akademik bisa menyeberang bulan kalender; dua penanggalan jalan terpisah.**
- Grup A = Senin & Rabu; Grup B = Selasa & Kamis; Jumat dipakai bergantian untuk capai kuota 10.
- Jumat giliran kena libur nasional → **tetap dihitung**, digeser ke Jumat berikutnya.
- Kekurangan meeting diganti hari **Sabtu**.

### 6.3 Kurikulum & kenaikan
- Tangga Level → beberapa Term; 1 Term = 1 bulan akademik.
- Siswa naik term **sebagai kohort**; kohort tetap sama walau guru berganti tiap bulan.
- 5 program: kenaikan otomatis tiap siklus, hampir semua siswa naik.
- Calistung & Montessori: **guru menentukan waktu kenaikan** berdasarkan selesainya tahapan silabus, tanpa jadwal tetap.
- Level & term awal siswa baru dari **placement test** (speaking + written).

### 6.4 Penilaian
- 1 nilai skala 1–5 **per meeting**, dari pengamatan umum, tanpa rincian komponen.
- Perilaku: 6 nilai **IMPACT**, sekali per siklus, pakai rubrik.
- Unit test: 1–5, **3.0 = batas kesiapan naik**.
- Cambridge Mock: KidsEnglish tiap 4 term, TeensEnglish tiap 6 term.
- Montessori: penilaian **sepenuhnya kualitatif, harian**.

### 6.5 Mutu pengajaran
- Teacher Coordinator mengobservasi tiap guru **≥2×/bulan**, skor 1–5.
- 1 coordinator membawahi 5–8 guru.
- Coordinator juga mengevaluasi kehadiran siswa, retensi, ringkasan nilai tiap bulan.

### 6.6 CRM
- Funnel: **Lead → Guest → Trial Class → Registrasi** (tiap tahap punya formulir sendiri).
- **Nomor WhatsApp orang tua = kunci penghubung antar tahap** (satu nomor dari lead sampai registrasi).
- Setiap lead wajib punya **kanal akuisisi** → hitung **CPA**.
- Status jadi registrasi → **data siswa otomatis tersedia di SIS, tanpa diketik ulang**.
- Peringatan otomatis: lead belum ditindaklanjuti, lead lewat batas follow up, siswa berhenti tanpa alasan tercatat.
- Terhubung WhatsApp Business (Meta Cloud API, Chatwoot, n8n — sudah berjalan) untuk pesan otomatis & eskalasi keluhan dari chatbot ke staf centre.
- Dasbor CRM: corong per kanal, **8 indikator utama**, CPA, tingkat retensi.

### 6.7 Keuangan
- Invoice program **Formal** dan **Non-Formal** terbit bulanan.
- Kas masuk/keluar dicatat harian, per centre, kategori configurable.
- 2 target bulanan: **OTP** (bayar tepat waktu) dan **WF** (total menunggak).
- **Exam Discount Voucher**: 12 bulan tanpa putus cuti → Rp1.200.000; 12 bulan dengan cuti ≤1 bulan → Rp600.000; cuti >1 bulan → **reset periode, tidak dapat voucher**.
- Payment gateway: Xendit (pencairan dana sekarang), gateway baru harus dukung transfer bank, e-wallet, QRIS. Kredensial Midtrans disediakan BEYOND.

## 7. Sepuluh hal yang paling sering salah dipahami (Bagian 4) — wajib jadi keputusan desain

| # | Butir | Keputusan skema (lihat `02-domain-model.md`) |
|---|---|---|
| 1 | Satuan hitung = pendaftaran; pertanyaan sebenarnya tentang orang. Jumlah per centre ≠ total organisasi | `person`/`student`/`enrollment` terpisah; 2 view hitung |
| 2 | Term (kurikulum) vs Siklus (delivery+billing) = dua jam terpisah | `term` di progression, `cycle` di delivery/invoice; keduanya FK berbeda di enrollment |
| 3 | Meeting per siklus = angka berubah dengan riwayat | `program_cycle_config` versioned by `effective_from`; `cycle` pegang snapshot `config_id` |
| 4 | Kohort bertahan walau penugasan guru berganti | `class_section` + `section_membership` + `teacher_assignment` berversi waktu |
| 5 | Presensi mengajar = uang → audit lengkap + periode dikunci sebelum export | `teaching_attendance` + `period_lock` + `audit_log` + trigger guard |
| 6 | Presensi kerja (HRIS) ≠ presensi mengajar (sistem ini) | hanya `teaching_attendance` yang dihitung untuk tunjangan |
| 7 | Offline-first di perangkat guru = keputusan arsitektur awal | PK UUID dari klien, `sync_batch`/`sync_item`, `client_op_id` idempoten |
| 8 | Input ≤60 detik / kelas 13 siswa | skema flat, 1 batch insert, tanpa lookup wajib per baris |
| 9 | Nilai harian hanya untuk guru + Teacher Coordinator | permission + view; rapor/unit test yang naik ke orang tua |
| 10 | Hampir semua siswa naik; nilai < batas tidak memblokir, tapi ditandai terbuka | `promotion_event` dengan `below_readiness_flag` + `note_text`, tanpa constraint pemblokir |

## 8. Matriks konfigurasi program (Bagian 5) — data seed

| Program | Level | Term | Total | Unit test | Cambridge Mock | Kenaikan level |
|---|---|---|---|---|---|---|
| KidsEnglish | 5 | 12 | 60 | tiap term | tiap 4 term | otomatis |
| TeensEnglish | 8 | 6 | 48 | tiap term | tiap 6 term | otomatis |
| SpeakNow | 4 | 2 | 8 | writing tiap term; presentasi tiap 2 term | — | otomatis |
| Cambridge Maths | 6 | 12 | 72 | tiap term | — | otomatis |
| Bimbel Mat. SD | 6 | 12 | 72 | tiap term | — | otomatis |
| Calistung | 4 | 2 | 8 | saat tahapan selesai (2–4 bulan) | — | guru + koordinator |
| Montessori Academy | — | — | — | tidak ada | — | guru + koordinator |

Perhatikan: Calistung = `teacher_decided` tapi tetap punya level/term 4×2 sebagai kerangka. Montessori Academy = **tanpa level/term tetap** → hanya kerangka user-definable (D6).

## 9. Kebutuhan non-fungsional (Bagian 9)

| Aspek | Kebutuhan |
|---|---|
| Arsitektur klien | PWA, tanpa instalasi toko aplikasi, jalan di Android/iOS/laptop |
| Operasi luring | modul guru penuh tanpa jaringan; sync otomatis; **pengiriman dua kali tidak tercatat dua kali** |
| Kecepatan input | 13 siswa <60 detik, perangkat menengah, tanpa jaringan |
| Keamanan perangkat | perangkat didaftarkan per pengguna; dicabut → data lokal terhapus pada sync berikutnya |
| Jejak audit | nilai, presensi mengajar, transaksi keuangan: before/after/aktor/waktu/**perangkat** |
| Cakupan akses | per centre untuk semua peran operasional; guru hanya kelas ditugaskan |
| Keamanan pembayaran | ikut standar transaksi elektronik Indonesia (SPBE/PCI-aware, 2FA pada gateway) |
| Bahasa | UI Indonesia; istilah baku tetap Inggris (term, cycle, invoice) |
| Hosting | VPS BEYOND; vendor sediakan panduan install |
| Cadangan | harian otomatis, retensi 360 hari, terpisah dari server aplikasi |

## 10. Integrasi (Bagian 6 & 10)

| Sistem | Arah | Isi | Titik tembus DB |
|---|---|---|---|
| Payment gateway (mis. Midtrans) | 2 arah | terima bayar, cek status, cocokkan ke invoice otomatis | `gateway_transaction`, `payment`, `reconciliation` |
| Moodle (LMS) | 2 arah | sinkron akun + course enrollment ikut data SIS | `moodle_user_link`, `moodle_sync_state` |
| WhatsApp (dorong) | push | rapor terbit, pengumuman kelas pengganti, pengingat jatuh tempo | `notification_log`, `invoice_reminder_log` |
| WhatsApp chatbot (tarik) | pull | eskalasi keluhan + ringkasan percakapan ke Portal Admin centre | `whatsapp_escalation` |

Ketentuan LMS (Bagian 6): SSO sekali jalan untuk siswa/orang tua/guru; enrollment & penugasan guru otomatis memicu akun/course di Moodle; struktur course disiapkan bersama tim akademik; **nilai & progres Moodle tinggal di Moodle** → SIS hanya tampilkan ringkasan.

Ketentuan CRM (Bagian 7): menggantikan Google Sheets + Jotform; alur mengikuti rancangan BEYOND; WA = kunci; kanal akuisisi wajib; alert pola bermasalah; registrasi → SIS.

Ketentuan Keuangan (Bagian 8): kas harian per centre; invoice Formal/Non-Formal otomatis per bulan dari enrollment; payment gateway; status lunas/menunggak/sebagian; OTP & WF dihitung otomatis per bulan per program per centre vs target (OTP ≥85%, WF ≤0,4%); pengingat jatuh tempo via WhatsApp beberapa hari sebelum due date; laporan bulanan: arus kas, laba rugi per program, laba rugi per centre.

## 11. Keluaran vendor (Bagian 11)

1. Aplikasi web penuh, semua modul, 5 portal, terpasang di server BEYOND.
2. Moodle terpasang + terkonfigurasi + SSO.
3. Kode sumber lengkap + **hak penuh** BEYOND untuk ubah/pindah pemeliharaan.
4. **Dokumentasi skema basis data** + dokumentasi API (termasuk API payment gateway & API Moodle). ← track ini menghasilkan butir ini.
5. Runbook operasional bulanan: pembukaan siklus, penguncian presensi, penerbitan invoice, rekonsiliasi pembayaran, penerbitan rapor, pencabutan akses perangkat.
6. Pelatihan 5 kelompok: Super Admin, Admin centre, Teacher Coordinator + Education Consultant, guru, staf Finance.
7. Garansi + pendampingan pasca-luncur dengan SLA tertulis.

## 12. Pertanyaan wajib proposal (Bagian 12)

Q1 model enrollment 2 program/2 centre + dua angka hitung · Q2 perubahan 10→8 meeting Jan 2027 tanpa ubah laporan lama · Q3 offline putus di tengah input, perangkat mati, dibuka 3 hari kemudian · Q4 cegah/deteksi/telusuri perubahan presensi mengajar setelah periode dikunci · Q5 bukti input <60 detik + prototipe · Q6 rancangan SSO + efek pencabutan akses · Q7 daftar gateway + pencocokan pembayaran otomatis · (nomor 8 absen di dokumen) · Q9 pemelihara pasca-garansi + SLA · Q10 keberlangsungan bila vendor berhenti · Q11 bagian paling berisiko + antisipasi.

Q1–Q4 = 100% domain data → dijawab di `docs/04-answer-proposal-q1-q4.md`.

## 13. Kriteria evaluasi & bobot (Bagian 13)

| Kriteria | Bobot |
|---|---|
| Pemahaman model data SIS (jawaban Q1–Q4) | **25%** |
| Rancangan modul Keuangan & CRM | 20% |
| Rancangan modul guru & kecepatan input | 15% |
| Kemampuan luring (antrean data, pemulihan gagal sync) | 10% |
| Integrasi Moodle & payment gateway | 10% |
| Pemeliharaan & keberlanjutan | 10% |
| Harga | 10% |

Harga dipisah per komponen: pembangunan, hosting/tahun, pemeliharaan/tahun, langganan payment gateway, tarif per hari kerja untuk perubahan di luar lingkup.

## 14. Rencana waktu (Bagian 14)

| Tahap | Catatan skema |
|---|---|
| Pengiriman proposal / penunjukan & mobilisasi | — |
| **Fase 1**: SIS inti + Keuangan inti | pakai konfigurasi 10 meeting/siklus → seed `program_cycle_config` versi awal |
| **Fase 2**: CRM + integrasi WhatsApp | funnel, kanal, alert, eskalasi |
| **Fase 3**: LMS Moodle + SSO | `moodle_user_link`, `moodle_sync_state`, `sso_session` |
| Peralihan silabus internal — **Jan 2027** | 10 → 8 meeting/siklus. **Tidak ada perubahan sistem** → cukup INSERT 1 baris `program_cycle_config` baru |
| Uji coba terbatas | 1 program, 1 centre, 1 siklus penuh, semua modul |
| Peluncuran menyeluruh | setelah uji coba tanpa kehilangan data |

## 15. Yang disediakan BEYOND (Bagian 15)

- VPS + domain, termasuk subdomain Moodle.
- 1 administrator sistem internal + cadangan (penanggung jawab harian, titik kontak tunggal).
- **Data awal siswa dan pendaftaran aktif dalam spreadsheet** → butuh `import_batch` + mapping sheet→tabel.
- Kredensial payment gateway (Midtrans).

Catatan penting: **BEYOND tidak punya tim pengembang internal.** Sistem harus dioperasikan staf administrasi non-teknis dan dipelihara pihak ketiga mana pun dari dokumentasi → skema wajib self-documenting (`COMMENT ON`), nama tabel/field konsisten, kamus data, tanpa keanehan vendor-specific.
