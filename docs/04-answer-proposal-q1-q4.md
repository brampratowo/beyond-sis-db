# 04 — Jawaban Pertanyaan Wajib Proposal Q1–Q4 (Bagian 12)

Semuanya domain model data = 25% bobot evaluasi (Bagian 13). Nama tabel merujuk `db/ddl/*`.

---

## Q1 — Satu siswa terdaftar di dua program di dua centre. Bagaimana memodelkan? Angka apa untuk "siswa per centre" vs "siswa organisasi"?

**Model tiga lapis:**

```
person  (1 baris = 1 manusia, kunci = id uuid)
  └─ student  (person yang pernah/ sedang terdaftar; student_code unik)
      └─ enrollment  (satuan PENDAFTARAN: student × program × teaching_centre × periode)
```

Anak示例: Budi (person `P1`, student `S1`) ikut Cambridge Maths di Sentani Rokim dan Calistung di Entrop:

```sql
INSERT INTO identity.person     (id, full_name) VALUES ('P1','Budi');
INSERT INTO identity.student    (person_id, student_code) VALUES ('P1','BXY-00412');  -- PK student = person_id
INSERT INTO identity.enrollment (id, student_id, program_id, teaching_centre_id, billing_centre_id, study_mode, status)
VALUES ('E1','P1','<CambridgeMaths>','<SNROKIM>','<SNROKIM>','formal','active'),
       ('E2','P1','<Calistung>','     <ENTROP>','<ENTROP>','non_formal','active');
```

- Dua enrollment = dua jadwal, dua kohort (`section_membership`), dua presensi, **dua invoice per siklus** (tagihan mengikuti pendaftaran, bukan orang), dan dua baris `moodle_sync_state`.
- `billing_centre_id` dipisah dari `teaching_centre_id` karena centre pengajar & centre penagih bisa beda (kelas gabungan/lintas centre).

**Dua angka, selalu ditampilkan terpisah dan berlabel:**

| Metrik | Sumber | Query | Label UI |
|---|---|---|---|
| per centre | `identity.v_student_count_per_centre` | `count(enrollment)` aktif per `teaching_centre_id` | "Pendaftaran aktif di centre ini" |
| organisasi | `identity.v_unique_student_org` | `count(DISTINCT student_id)` pada enrollment aktif | "Siswa unik BEYOND" |

Konsekuensi yang kami terima apa adanya: **7 × angka centre > angka organisasi** — bukan bug, memang dua pertanyaan berbeda. Rapor, kehadiran, dan invoice menempel pada `enrollment_id`; identitas, kontak (WA), wali, dan voucher menempel pada `person_id`/`student_id`. Voucher exam discount dihitung per **orang** (`exam_discount_voucher.student_id`) karena aturan 12-bulan adalah kontinuitas belajar, bukan per pendaftaran.

---

## Q2 — Target berubah 10 → 8 pertemuan per siklus pada Januari 2027, tanpa mengubah laporan tahun sebelumnya?

**Satu INSERT, nol UPDATE, nol deploy kode.**

Konfigurasi jumlah pertemuan adalah tabel berversi: `curriculum.program_cycle_config(program_id, effective_from, meetings_per_cycle, classes_per_year)` dengan `UNIQUE(program_id, effective_from)` dan trigger `ifx_append_only` yang **menolak UPDATE dan DELETE** pada baris lama.

```sql
-- hari-H, Januari 2027:
INSERT INTO curriculum.program_cycle_config
       (program_id, effective_from, meetings_per_cycle, classes_per_year, note)
SELECT id, DATE '2027-01-01', 8, 96, 'peralihan silabus internal' FROM identity.program;
```

Penahan utamanya bukan tabel config, tapi **snapshot di siklus**:

```
delivery.cycle.config_id  ->  FK ke baris program_cycle_config yang berlaku saat itu
delivery.cycle.meetings_planned  ->  angka DISALIN saat siklus dibuka
delivery.meeting.seq_no  ->  jumlah baris meeting = meetings_planned siklus itu
```

- Siklus 2026 → `config_id` menunjuk baris `effective_from 2025-01-01, meetings=10`; `meetings_planned = 10`.
- Siklus 2027 ke atas → `config_id` menunjuk baris `2027-01-01, meetings=8`; `meetings_planned = 8`.
- Laporan lama membaca `cycle.meetings_planned` dan jumlah baris `meeting` milik siklus itu, **tidak pernah membaca konfigurasi kini** → laporan 2026 tidak bergeser sedikit pun.
- Aturan Jumat-libur-digeser & makeup Sabtu dieksekusi generator saat siklus dibuka, hasilnya jadi baris `meeting` permanen → riwayat tersimpan, bukan dihitung ulang dari rumus.
- Yang **tidak** berubah: harga invoice (tetap per siklus), dan tidak ada re-run historis.

Bila ternyata perlu "mundur" ke 10: INSERT lagi baris `effective_from 2028-…`. Riwayat tetap utuh.

---

## Q3 — Aplikasi guru kehilangan jaringan di tengah input, perangkat dimatikan, dibuka lagi 3 hari kemudian. Langkah demi langkah apa yang terjadi pada data?

**Hari H (jaringan putus, input berjalan):**
1. Layar kehadiran/nilai sudah dimuat dari cache lokal (13 nama siswa per meeting, dibaca saat masih daring).
2. Setiap ketukan guru → baris ditulis ke LocalDB perangkat (SQLite-WASM/IndexedDB): `id` = uuid dibuat di perangkat, `meeting_id`, `enrollment_id`, `status`/`score`, `recorded_at`, `device_id`, `op_id` (client_op_id) — **semua commit lokal, tanpa menunggu server**.
3. Antrean kirim di LocalDB menandai item `pending`. Tidak ada spinner, tidak ada request yang menggantung — UI tetap responsif (target <60 detik tercapai justru karena tidak ada roundtrip).

**Perangkat dimatikan sebelum sinkron:**
4. LocalDB persisten (bukan memory). Baris `pending` tetap ada. Tidak ada data "di tengah" yang rusak karena setiap ketukan sudah ter-commit lokal; state layar (meeting mana, draft apa) ikut disimpan sebagai satu baris form-state.

**3 hari kemudian, perangkat menyala & ada jaringan:**
5. PWA boot → baca antrean → susun `sync_batch` (`user_id`, `device_id`, N item) → `POST /sync`.
6. Server membuka 1 transaksi per `sync_item`: cek `client_op_id` di `platform.sync_item` → bila belum pernah → INSERT ke `academics.attendance` / `academics.daily_score` dengan `source='offline_sync'`, `recorded_at` asli (hari H), `device_id` = perangkat itu.
7. Tiga hasil mungkin per item, dan **item lain tidak ikut gagal**:
   - `applied` → normal.
   - `DUPLICATE_IGNORED` → klien retry batch yang sama (sinyal timeout): tabrakan pada `sync_item.client_op_id` → item dianggap sukses, **bukan baris ganda**. Jaring kedua: `UNIQUE(meeting_id, enrollment_id)`.
   - `LOCKED_PERIOD` → 3 hari itu coordinator sudah mengunci presensi untuk ekspor tunjangan. Guard trigger menolak. Item disimpan utuh di `sync_item.payload` (jsonb) + `platform.pending_review` + alert ke Super Admin. **Data tidak hilang — tertahan, terlihat, dan ada pemiliknya.**
8. Klien menerima ack per item; hanya item `applied`/`DUPLICATE_IGNORED` yang dibuang dari antrean. Item `pending_review` ditampilkan ke guru sebagai "belum tersimpan resmi — hubungi admin", bukan hilang diam-diam.
9. Koreksi resmi: admin buat `unlock_request` (alasan, disetujui orang lain / four-eyes) → data di-apply → re-lock. Semua tercatat di `platform.audit_log` (before/after/aktor/**perangkat**/waktu/source).
10. Perhitungan tunjangan tidak pernah membaca baris mentah: hanya `finance.v_teaching_allowance` yang memfilter cycle ber-`period_lock` aktif. Angka ekspor tidak berubah setelah ekspor kecuali lewat jalur unlock yang berjejak.

**Yang bikin kasus ini gagal di SIS generik:** sistem sekolah biasa menyimpan ID lokal integer per perangkat (bentrok antar perangkat), mengirim form sebagai satu POST (mati sebelum POST = hilang semua), dan tidak punya konsep periode terkunci. Di sini: uuid dari klien, antrean per-item idempoten, dan lock + pending_review.

---

## Q4 — Presensi mengajar jadi dasar pembayaran tunjangan. Bagaimana mencegah, mendeteksi, menelusuri perubahan setelah periode dikunci?

**Pencegahan ( berlapis, tidak bergantung UI )**
| Lapis | Mekanisme |
|---|---|
| DB trigger | `platform.ifx_locked_meeting_guard()` pada `BEFORE UPDATE OR DELETE` di `academics.teaching_attendance` → `RAISE EXCEPTION` bila cycle-nya punya `period_lock` aktif (locked_at terisi, unlocked_at kosong). Berlaku untuk **semua** koneksi: aplikasi, psql, sync worker, import. |
| Jalur resmi | Perubahan hanya mungkin setelah `platform.unlock_request` dibuat (alasan wajib) **dan disetujui akun lain** (`CHECK approved_by <> requested_by`). Lalu re-lock = baris `period_lock` baru. |
| Hak akses | Peran operasional (teacher, coordinator centre) tidak punya `UPDATE`/`DELETE` pada `academics.teaching_attendance` — ditegakkan GRANT PostgreSQL per role aplikasi, bukan filter menu. Guard juga menghukum superuser yang lupa. |
| Append-only | `teaching_attendance` tidak menerima DELETE (trigger). Kehadiran yang salah tidak "dihapus" — dikoreksi lewat unlock atau reversal ber-`source`. |
| Export | Tunjangan hanya dibaca dari `finance.v_teaching_allowance` (sumber = cycle locked). Export dari tabel mentah tidak tersedia bagi peran keuangan. |

**Deteksi**
- Setiap UPDATE/DELETE yang lolos (artinya: setelah unlock resmi) memicu `platform.ifx_audit()` → baris `audit_log` dengan `before` & `after` jsonb penuh, `actor_user_id`, `actor_device_id`, `occurred_at`, `source`.
- Selisih post-lock bisa diperiksa set-based: jumlah `audit_log` bertabel `academics.teaching_attendance` dengan `action='update'` dan `occurred_at > locked_at`, digabung ke daftar `unlock_request` periode itu. Jumlahnya **harus** cocok; sisanya anomali.
- Rekonsiliasi angka: `count(teaching_attendance)` vs `meetings_planned` per cycle (`delivery.v_cycle_meeting_progress`) dan vs jumlah baris `attendance` meeting tersebut — lompatan setelah kunci terlihat sebagai selisih.
- Guard juga menolak `meeting.status='held'` yang berubah menjadi `cancelled` pada cycle terkunci (satu-satunya cara "menghapus" kehadiran secara halus).

**Penelusuran**
Kueri forensik standar, contoh: "siapa mengubah kehadiran guru X pada siklus ini?"
```sql
SELECT a.occurred_at, a.action, a.actor_user_id, u.username,
       a.actor_device_id, d.platform, a.source,
       (a.before->>'role') AS before_role, (a.after->>'role') AS after_role,
       a.before->>'recorded_at' AS before_at, a.after->>'recorded_at' AS after_at
FROM   platform.audit_log a
LEFT   JOIN identity.user_account u ON u.id = a.actor_user_id
LEFT   JOIN identity.device_registration d ON d.id = a.actor_device_id
WHERE  a.table_name = 'academics.teaching_attendance'
  AND  a.row_id = :row_id
ORDER  BY a.occurred_at;
```
Rantai jejak lengkap: nilai sebelum → nilai sesudah → pelaku → waktu → **perangkat** (sesuai NFR Bagian 9), plus siapa yang mengizinkan (`unlock_request.approved_by`) dan siapa yang mengunci ulang (`period_lock.locked_by`), karena `period_lock` append-only.

Batas yang kami akui: kalau DBA langsung menulis dengan `session_replication_role = replica` ( bypass trigger), guard tidak menahan — karena itu audit `source='import'/'system'` wajib ada, dan akses DB produksi dipegang administrator internal BEYOND dengan credential terpisah, bukan dibagikan ke vendor. Retensi `audit_log` 360 hari mengikuti kebijakan cadangan.
