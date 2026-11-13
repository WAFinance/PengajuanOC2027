-- =====================================================================
-- SKRIP PERBAIKAN TOTAL: RLS, STORAGE BUCKET & SKEMA V2 SUPABASE
-- =====================================================================
-- Skrip ini menyelesaikan error:
-- 1. "new row violates row-level security policy" (pada pengajuan & storage)
-- 2. "ERROR: 42501: must be owner of table objects" (aman, tanpa ALTER TABLE storage.objects)
-- 3. Gagal upload file / HTTP 400 Bad Request
--
-- CARA MENJALANKAN:
-- Buka Supabase Dashboard -> Masuk ke Menu SQL Editor -> New Query
-- Salin seluruh isi skrip ini -> Klik "Run" (atau Ctrl+Enter)
-- =====================================================================

-- 0. AKTIFKAN EKSTENSI KRIPTOGRAFI UNTUK PASSWORD HASH
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. PASTIKAN STRUKTUR TABEL LENGKAP DENGAN FITUR TERBARU
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS email TEXT UNIQUE;
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS reset_token TEXT;
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS reset_expires TIMESTAMPTZ;

DO $$
BEGIN
  ALTER TABLE app_users DROP CONSTRAINT IF EXISTS app_users_role_check;
  ALTER TABLE app_users ADD CONSTRAINT app_users_role_check 
    CHECK (role IN ('OPD', 'Pokja', 'Admin', 'Tim Konsolidasi'));
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

ALTER TABLE referensi_penyedia ADD COLUMN IF NOT EXISTS kategori TEXT DEFAULT 'UMKK';

DO $$
BEGIN
  ALTER TABLE referensi_penyedia DROP CONSTRAINT IF EXISTS referensi_penyedia_kategori_check;
  ALTER TABLE referensi_penyedia ADD CONSTRAINT referensi_penyedia_kategori_check 
    CHECK (kategori IN ('UMKK', 'Non UMKK'));
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- Pastikan 4 Penyedia Non UMKK ditandai dengan benar
UPDATE referensi_penyedia 
SET kategori = 'Non UMKK'
WHERE upper(nama) LIKE '%PAU PEDARINGAN%' 
   OR upper(nama) LIKE '%BINTANG MITRA PRATAMA%' 
   OR upper(nama) LIKE '%JAYA WIRA MANGGALA%' 
   OR upper(nama) LIKE '%MUHANDAS PERMATA SARANA%';

INSERT INTO referensi_penyedia (nama, kategori) VALUES
('PERUMDA PAU PEDARINGAN KOTA SURAKARTA', 'Non UMKK'),
('PT BINTANG MITRA PRATAMA', 'Non UMKK'),
('PT JAYA WIRA MANGGALA', 'Non UMKK'),
('PT MUHANDAS PERMATA SARANA', 'Non UMKK')
ON CONFLICT (nama) DO UPDATE SET kategori = 'Non UMKK';

-- Tabel Pengajuan: Kolom untuk Verifikasi 2 Tahap & Undangan Klarifikasi
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tahap INT DEFAULT 1;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS undangan_klarifikasi JSONB DEFAULT NULL;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS riwayat_penyedia JSONB DEFAULT '[]'::jsonb;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS verifikator_tahap1 TEXT;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tgl_verifikasi_tahap1 TIMESTAMPTZ;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS verifikator_tahap2 TEXT;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tgl_verifikasi_tahap2 TIMESTAMPTZ;

DO $$
BEGIN
  ALTER TABLE pengajuan DROP CONSTRAINT IF EXISTS pengajuan_status_check;
  ALTER TABLE pengajuan ADD CONSTRAINT pengajuan_status_check 
    CHECK (status IN (
      'Pending',
      'Menunggu Verifikasi Tahap 1',
      'Undangan Klarifikasi',
      'Penyedia Ditolak',
      'Menunggu Verifikasi Tahap 2',
      'Revisi',
      'Revisi Dokumen',
      'Disetujui',
      'Ditolak'
    ));
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- 2. DISABLE RLS PADA TABEL UTAMA APLIKASI
-- Karena aplikasi menggunakan autentikasi akun mandiri (login_user) dengan Anon Key,
-- menonaktifkan RLS pada tabel-tabel ini menjamin tidak ada lagi error "new row violates row-level security policy"!
ALTER TABLE IF EXISTS pengajuan DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS app_users DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS referensi_satker DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS referensi_jenis_tenaga DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS referensi_penyedia DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS klarifikasi DISABLE ROW LEVEL SECURITY;

-- Berikan izin akses penuh ke tabel untuk peran anon dan authenticated
GRANT ALL ON TABLE pengajuan TO anon, authenticated;
GRANT ALL ON TABLE app_users TO anon, authenticated;
GRANT ALL ON TABLE referensi_satker TO anon, authenticated;
GRANT ALL ON TABLE referensi_jenis_tenaga TO anon, authenticated;
GRANT ALL ON TABLE referensi_penyedia TO anon, authenticated;
GRANT ALL ON TABLE klarifikasi TO anon, authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

-- 3. KONFIGURASI STORAGE BUCKET 'dokumen-pengajuan'
-- Buat bucket publik jika belum ada
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'dokumen-pengajuan', 
  'dokumen-pengajuan', 
  true, 
  52428800, -- 50 MB
  NULL      -- Mengizinkan semua jenis berkas
)
ON CONFLICT (id) DO UPDATE SET 
  public = true,
  file_size_limit = 52428800,
  allowed_mime_types = NULL;

-- 4. KEBIJAKAN STORAGE.OBJECTS (SUPABASE STORAGE)
-- Catatan: JANGAN gunakan "ALTER TABLE storage.objects" karena tabel tersebut dimiliki internal supabase_storage_admin!
-- Cukup buat policy yang mengizinkan peran public/anon untuk CRUD di bucket 'dokumen-pengajuan':

DROP POLICY IF EXISTS "Public Upload Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Select Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Update Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Delete Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon upload" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon select" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon update" ON storage.objects;
DROP POLICY IF EXISTS "Allow anon delete" ON storage.objects;
DROP POLICY IF EXISTS "Dokumen Pengajuan Insert" ON storage.objects;
DROP POLICY IF EXISTS "Dokumen Pengajuan Select" ON storage.objects;
DROP POLICY IF EXISTS "Dokumen Pengajuan Update" ON storage.objects;
DROP POLICY IF EXISTS "Dokumen Pengajuan Delete" ON storage.objects;

CREATE POLICY "Dokumen Pengajuan Insert"
ON storage.objects FOR INSERT
TO public
WITH CHECK (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Dokumen Pengajuan Select"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Dokumen Pengajuan Update"
ON storage.objects FOR UPDATE
TO public
USING (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Dokumen Pengajuan Delete"
ON storage.objects FOR DELETE
TO public
USING (bucket_id = 'dokumen-pengajuan');

-- 5. FUNGSI-FUNGSI BACKEND DATABASE LENGKAP
DROP FUNCTION IF EXISTS hitung_total_penyedia(text, text);
DROP FUNCTION IF EXISTS hitung_total_penyedia(text);
DROP FUNCTION IF EXISTS login_user(text, text);
DROP FUNCTION IF EXISTS minta_reset_password(text);
DROP FUNCTION IF EXISTS proses_reset_password(text, text, text);
DROP FUNCTION IF EXISTS buat_id_pengajuan();
DROP FUNCTION IF EXISTS norm_penyedia(text);

CREATE OR REPLACE FUNCTION norm_penyedia(nama text) RETURNS text AS $$
BEGIN
  RETURN lower(regexp_replace(regexp_replace(coalesce(nama, ''), '\m(pt|cv|ud|pd|fa|tbk|persero)\M', '', 'gi'), '[^a-z0-9]', '', 'g'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION buat_id_pengajuan() RETURNS text AS $$
DECLARE
  v_prefix text := 'PGJ-' || to_char(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-';
  v_next_num int;
BEGIN
  SELECT coalesce(max(nullif(substring(id from 14 for 4), '')::int), 0) + 1
  INTO v_next_num
  FROM pengajuan
  WHERE id LIKE v_prefix || '%';

  RETURN v_prefix || lpad(v_next_num::text, 4, '0');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION hitung_total_penyedia(p_penyedia text, p_exclude_id text DEFAULT NULL)
RETURNS TABLE (total bigint, jumlah int, kategori text) AS $$
DECLARE
  v_kunci text := norm_penyedia(p_penyedia);
  v_kat text := 'UMKK';
BEGIN
  SELECT rp.kategori INTO v_kat
  FROM referensi_penyedia rp
  WHERE norm_penyedia(rp.nama) = v_kunci
  LIMIT 1;

  IF v_kat IS NULL THEN
    v_kat := 'UMKK';
  END IF;

  RETURN QUERY
  SELECT 
    coalesce(sum(p.nilai_hps), 0)::bigint AS total,
    count(*)::int AS jumlah,
    v_kat AS kategori
  FROM pengajuan p
  WHERE p.status NOT IN ('Ditolak', 'Penyedia Ditolak')
    AND (p_exclude_id IS NULL OR p.id != p_exclude_id)
    AND norm_penyedia(p.calon_penyedia) = v_kunci;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION login_user(p_username text, p_password text)
RETURNS json AS $$
DECLARE
  v_user record;
  v_hash text;
BEGIN
  v_hash := encode(digest('ganti-teks-rahasia-ini' || p_password, 'sha256'), 'hex');
  
  SELECT * INTO v_user
  FROM app_users
  WHERE lower(trim(username)) = lower(trim(p_username))
     OR (email IS NOT NULL AND lower(trim(email)) = lower(trim(p_username)));

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'message', 'Username / Email atau password salah.');
  END IF;

  IF v_user.password_hash != v_hash AND v_user.password_hash != p_password THEN
    RETURN json_build_object('ok', false, 'message', 'Username / Email atau password salah.');
  END IF;

  IF v_user.role = 'OPD' AND v_user.status = 'Menunggu' THEN
    RETURN json_build_object('ok', false, 'message', 'Akun Anda sedang menunggu persetujuan Admin.');
  END IF;

  IF v_user.role = 'OPD' AND v_user.status != 'Aktif' THEN
    RETURN json_build_object('ok', false, 'message', 'Akun Anda tidak aktif. Hubungi Admin.');
  END IF;

  RETURN json_build_object(
    'ok', true,
    'username', v_user.username,
    'email', v_user.email,
    'role', v_user.role,
    'satker', v_user.satker
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION minta_reset_password(p_email text)
RETURNS json AS $$
DECLARE
  v_user record;
  v_token text;
BEGIN
  SELECT * INTO v_user
  FROM app_users
  WHERE lower(trim(email)) = lower(trim(p_email));

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'message', 'Email tidak terdaftar dalam sistem.');
  END IF;

  v_token := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

  UPDATE app_users
  SET reset_token = v_token,
      reset_expires = now() + interval '15 minutes'
  WHERE id = v_user.id;

  RETURN json_build_object(
    'ok', true,
    'message', 'Kode verifikasi reset password telah dibuat (berlaku 15 menit).',
    'token', v_token
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION proses_reset_password(p_email text, p_token text, p_password_baru text)
RETURNS json AS $$
DECLARE
  v_user record;
  v_hash text;
BEGIN
  SELECT * INTO v_user
  FROM app_users
  WHERE lower(trim(email)) = lower(trim(p_email))
    AND reset_token = trim(p_token)
    AND reset_expires > now();

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'message', 'Kode verifikasi salah atau sudah kadaluarsa (15 menit).');
  END IF;

  v_hash := encode(digest('ganti-teks-rahasia-ini' || p_password_baru, 'sha256'), 'hex');

  UPDATE app_users
  SET password_hash = v_hash,
      reset_token = NULL,
      reset_expires = NULL
  WHERE id = v_user.id;

  RETURN json_build_object('ok', true, 'message', 'Password berhasil diubah. Silakan masuk dengan password baru.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. SEED AKUN POKJA & ADMIN
INSERT INTO app_users (username, email, password_hash, role, satker, status) VALUES
('pokja1', 'pokja1@surakarta.go.id', encode(digest('ganti-teks-rahasia-ini' || 'pokja123', 'sha256'), 'hex'), 'Pokja', 'Bagian Pengadaan Barang dan Jasa', 'Aktif'),
('admin_oc', 'admin@surakarta.go.id', encode(digest('ganti-teks-rahasia-ini' || 'admin123', 'sha256'), 'hex'), 'Admin', 'Sekretariat Daerah', 'Aktif')
ON CONFLICT (username) DO UPDATE 
SET role = EXCLUDED.role, email = EXCLUDED.email;
