-- ============================================================
-- SKRIP MIGRASI SUPABASE v2: SISTEM PENGAJUAN ALIH DAYA
-- Fitur: 3 Role (OPD, Pokja, Admin), Verifikasi 2 Tahap,
--        Email & Lupa Password, Undangan Klarifikasi, UMKK & Non UMKK
-- Jalankan di: Supabase Dashboard -> SQL Editor -> New Query -> Run
-- ============================================================

-- 1. TABEL APP_USERS: Tambah email dan sesuaikan role (OPD, Pokja, Admin, Tim Konsolidasi)
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS email TEXT UNIQUE;
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS reset_token TEXT;
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS reset_expires TIMESTAMPTZ;

-- Update constraint role app_users jika ada
DO $$
BEGIN
  ALTER TABLE app_users DROP CONSTRAINT IF EXISTS app_users_role_check;
  ALTER TABLE app_users ADD CONSTRAINT app_users_role_check 
    CHECK (role IN ('OPD', 'Pokja', 'Admin', 'Tim Konsolidasi'));
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- 2. TABEL REFERENSI_PENYEDIA: Tambah parameter kategori UMKK / Non UMKK
ALTER TABLE referensi_penyedia ADD COLUMN IF NOT EXISTS kategori TEXT DEFAULT 'UMKK';

DO $$
BEGIN
  ALTER TABLE referensi_penyedia DROP CONSTRAINT IF EXISTS referensi_penyedia_kategori_check;
  ALTER TABLE referensi_penyedia ADD CONSTRAINT referensi_penyedia_kategori_check 
    CHECK (kategori IN ('UMKK', 'Non UMKK'));
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- Update 4 Penyedia Non UMKK sesuai instruksi
UPDATE referensi_penyedia 
SET kategori = 'Non UMKK'
WHERE upper(nama) LIKE '%PAU PEDARINGAN%' 
   OR upper(nama) LIKE '%BINTANG MITRA PRATAMA%' 
   OR upper(nama) LIKE '%JAYA WIRA MANGGALA%' 
   OR upper(nama) LIKE '%MUHANDAS PERMATA SARANA%';

-- Pastikan 4 penyedia tersebut ada di tabel referensi_penyedia jika belum ada
INSERT INTO referensi_penyedia (nama, kategori) VALUES
('PERUMDA PAU PEDARINGAN KOTA SURAKARTA', 'Non UMKK'),
('PT BINTANG MITRA PRATAMA', 'Non UMKK'),
('PT JAYA WIRA MANGGALA', 'Non UMKK'),
('PT MUHANDAS PERMATA SARANA', 'Non UMKK')
ON CONFLICT (nama) DO UPDATE SET kategori = 'Non UMKK';

-- 3. TABEL PENGAJUAN: Tambah field untuk 2 Tahap Verifikasi & Undangan Klarifikasi
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tahap INT DEFAULT 1;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS undangan_klarifikasi JSONB DEFAULT NULL;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS riwayat_penyedia JSONB DEFAULT '[]'::jsonb;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS verifikator_tahap1 TEXT;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tgl_verifikasi_tahap1 TIMESTAMPTZ;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS verifikator_tahap2 TEXT;
ALTER TABLE pengajuan ADD COLUMN IF NOT EXISTS tgl_verifikasi_tahap2 TIMESTAMPTZ;

-- Perbarui CHECK constraint status pengajuan agar mendukung alur baru dan lama
DO $$
BEGIN
  ALTER TABLE pengajuan DROP CONSTRAINT IF EXISTS pengajuan_status_check;
  ALTER TABLE pengajuan ADD CONSTRAINT pengajuan_status_check 
    CHECK (status IN (
      'Pending',                        -- Status awal / Menunggu Tahap 1
      'Menunggu Verifikasi Tahap 1',    -- Admin Verifikasi Penyedia
      'Undangan Klarifikasi',           -- Diundang rapat klarifikasi karena > 15M dsb
      'Penyedia Ditolak',               -- Tahap 1 ditolak, OPD perlu ganti penyedia
      'Menunggu Verifikasi Tahap 2',    -- Lolos Tahap 1, Menunggu Pokja periksa dokumen
      'Revisi',                         -- Revisi umum
      'Revisi Dokumen',                 -- Pokja minta revisi KAK / Kertas Kerja / HPS
      'Disetujui',                      -- Disetujui final oleh Pokja
      'Ditolak'                         -- Ditolak final
    ));
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- 4. FUNGSI HITUNG TOTAL PENYEDIA & CEK KATEGORI
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

-- 5. FUNGSI LOGIN DENGAN USERNAME ATAU EMAIL
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

-- 6. FUNGSI RESET PASSWORD (LUPA PASSWORD)
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

  -- Buat kode OTP 6-digit
  v_token := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

  UPDATE app_users
  SET reset_token = v_token,
      reset_expires = now() + interval '15 minutes'
  WHERE id = v_user.id;

  RETURN json_build_object(
    'ok', true,
    'message', 'Kode verifikasi reset password telah dibuat (berlaku 15 menit).',
    'token', v_token -- Disertakan agar bisa ditampilkan langsung/dikirimkan
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

-- 7. SEED AKUN CONTOH UNTUK POKJA & ADMIN
INSERT INTO app_users (username, email, password_hash, role, satker, status) VALUES
('pokja1', 'pokja1@surakarta.go.id', encode(digest('ganti-teks-rahasia-ini' || 'pokja123', 'sha256'), 'hex'), 'Pokja', 'Bagian Pengadaan Barang dan Jasa', 'Aktif'),
('admin_oc', 'admin@surakarta.go.id', encode(digest('ganti-teks-rahasia-ini' || 'admin123', 'sha256'), 'hex'), 'Admin', 'Sekretariat Daerah', 'Aktif')
ON CONFLICT (username) DO UPDATE 
SET role = EXCLUDED.role, email = EXCLUDED.email;
