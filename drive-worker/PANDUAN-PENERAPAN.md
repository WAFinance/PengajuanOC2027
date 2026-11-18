# Panduan Penerapan Perbaikan Keamanan

Isi paket:
- `index.html`      -> ganti di Cloudflare Pages (bersama `_headers`)
- `_headers`        -> letakkan di folder yang sama dengan index.html
- `worker.js`       -> ganti di Cloudflare Worker (pengajuanoc2027), lalu deploy
- `firestore.rules` -> tempel di Firebase Console > Firestore Database > Rules > Publish

## Urutan penerapan (lakukan di jam sepi)
1. **Deploy worker.js** (`wrangler deploy` atau tempel di editor Worker). Secret dan variabel tidak berubah.
2. **Publish firestore.rules** lalu **segera deploy index.html + _headers** ke Pages.
   Aturan baru dan frontend baru harus dipasang berdekatan: frontend lama tidak cocok dengan aturan baru.
3. **Login Admin pertama kali memakai EMAIL (bukan username).**
   Saat Admin masuk, aplikasi otomatis membuat entri `login_lookup` untuk semua akun
   (username -> email). Sebelum itu dijalankan, login dengan username belum berfungsi untuk siapa pun.
4. Setelah itu semua pengguna login seperti biasa (username atau email).

## Pengaturan tambahan di konsol (tidak bisa lewat kode)
- Firebase Console > Authentication > Settings: aktifkan **Email enumeration protection**.
- Google Cloud Console > APIs & Services > Credentials > API key Firebase:
  batasi ke **HTTP referrers** `https://pengajuanoc2027.pages.dev/*`
  (dan `http://localhost:8080/*` hanya selama pengujian).
- (Opsional, disarankan) Firebase App Check dengan reCAPTCHA untuk Firestore dan Auth.
- Wrangler: variabel `DEBUG_HEALTH` jangan diisi di produksi. `/health` kini hanya menjawab `{"ok":true}`.
- `_headers` memakai `Content-Security-Policy-Report-Only`. Buka aplikasi, cek Console browser.
  Jika tidak ada peringatan CSP, ganti nama header menjadi `Content-Security-Policy`.

## Uji di Rules Playground (Firebase Console > Firestore > Rules > Rules playground)
Aturan ini belum dijalankan di emulator. Mohon uji sebelum dipakai penuh:
1. Pengguna biasa membuat `users/{uid-sendiri}` dengan `role: "Admin"` -> HARUS ditolak.
2. Pengguna membuat `users/{uid-sendiri}` dengan `role: "OPD"`, `status: "Menunggu"` -> diizinkan.
3. Akun OPD A membaca `pengajuan/{id}` milik OPD B -> HARUS ditolak.
4. Akun OPD membaca daftar `pengajuan` tanpa filter `opd_pengaju` -> HARUS ditolak.
5. Akun OPD mengubah `status` menjadi `Disetujui` -> HARUS ditolak.
6. Pokja membaca pengajuan yang tidak didelegasikan kepadanya -> HARUS ditolak.
7. Admin membaca/mengubah pengajuan, mengubah status akun -> diizinkan.
8. Pengguna tanpa login membaca `users` -> HARUS ditolak; membaca `login_lookup/{username}` per ID -> diizinkan.

## Hal yang perlu diperhatikan
- Akun lama harus punya dokumen `users/{uid}` dengan ID = UID Firebase Auth
  (otomatis untuk akun yang dibuat lewat aplikasi ini). Akun yang dibuat manual dengan ID acak
  bisa terkunci; perbaiki lewat Firebase Console.
- Sesi login sekarang hanya berlaku selama tab terbuka; pengguna perlu login ulang bila tab ditutup.
- Password minimal 8 karakter untuk pendaftaran dan pembuatan akun baru.
- Registrasi mandiri tetap butuh persetujuan Admin, dan email belum diverifikasi.
- `login_lookup/{username}` bisa dibaca siapa pun yang tahu username-nya (hanya mengembalikan email).
  Ini kompromi supaya login dengan username tetap bisa dipakai tanpa membuka seluruh koleksi `users`.
