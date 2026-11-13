-- ============================================================
-- SKEMA DATABASE SUPABASE: APLIKASI PENGAJUAN ALIH DAYA
-- Jalankan skrip ini di: Supabase Dashboard -> SQL Editor -> New Query -> Run
-- ============================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. TABEL REFERENSI
CREATE TABLE IF NOT EXISTS referensi_satker (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nama TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS referensi_jenis_tenaga (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nama TEXT UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS referensi_penyedia (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nama TEXT UNIQUE NOT NULL
);

-- 3. TABEL PENGGUNA (USERS)
CREATE TABLE IF NOT EXISTS app_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('OPD', 'Tim Konsolidasi')),
  satker TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'Menunggu' CHECK (status IN ('Menunggu', 'Aktif', 'Nonaktif')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. TABEL PENGAJUAN
CREATE TABLE IF NOT EXISTS pengajuan (
  id TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT now(),
  opd_pengaju TEXT NOT NULL,
  nama_paket TEXT NOT NULL,
  calon_penyedia TEXT NOT NULL,
  nilai_hps BIGINT NOT NULL CHECK (nilai_hps > 0),
  jenis_tenaga_alih_daya TEXT NOT NULL,
  jumlah_tenaga INT NOT NULL CHECK (jumlah_tenaga > 0),
  status TEXT NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending', 'Revisi', 'Disetujui', 'Ditolak')),
  dokumen_kak TEXT,
  dokumen_kertas_kerja TEXT,
  dokumen_hps TEXT,
  link_katalog TEXT,
  catatan_umum TEXT,
  catatan_item JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_pengajuan_opd ON pengajuan(opd_pengaju);
CREATE INDEX IF NOT EXISTS idx_pengajuan_penyedia ON pengajuan(calon_penyedia);
CREATE INDEX IF NOT EXISTS idx_pengajuan_status ON pengajuan(status);
CREATE INDEX IF NOT EXISTS idx_pengajuan_created_at ON pengajuan(created_at DESC);

-- 5. TABEL KLARIFIKASI (CHAT)
CREATE TABLE IF NOT EXISTS klarifikasi (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pengajuan TEXT NOT NULL REFERENCES pengajuan(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now(),
  pengirim TEXT NOT NULL,
  role TEXT,
  pesan TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_klarifikasi_pengajuan ON klarifikasi(id_pengajuan, created_at ASC);

-- ============================================================
-- 6. FUNGSI BISNIS & VALIDASI
-- ============================================================

-- Fungsi normalisasi nama penyedia (menghilangkan PT/CV/spasi/tanda baca)
CREATE OR REPLACE FUNCTION norm_penyedia(nama text) RETURNS text AS $$
BEGIN
  RETURN lower(regexp_replace(regexp_replace(coalesce(nama, ''), '\m(pt|cv|ud|pd|fa|tbk|persero)\M', '', 'gi'), '[^a-z0-9]', '', 'g'));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Fungsi membuat ID Pengajuan unik format PGJ-YYYYMMDD-0001
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

-- Fungsi hitung akumulasi HPS penyedia (hanya status bukan 'Ditolak')
CREATE OR REPLACE FUNCTION hitung_total_penyedia(p_penyedia text, p_exclude_id text DEFAULT NULL)
RETURNS TABLE (total bigint, jumlah int) AS $$
DECLARE
  v_kunci text := norm_penyedia(p_penyedia);
BEGIN
  RETURN QUERY
  SELECT 
    coalesce(sum(p.nilai_hps), 0)::bigint AS total,
    count(*)::int AS jumlah
  FROM pengajuan p
  WHERE p.status != 'Ditolak'
    AND (p_exclude_id IS NULL OR p.id != p_exclude_id)
    AND norm_penyedia(p.calon_penyedia) = v_kunci;
END;
$$ LANGUAGE plpgsql STABLE;

-- Fungsi Login (menerima SHA-256 salt 'ganti-teks-rahasia-ini' atau teks biasa)
CREATE OR REPLACE FUNCTION login_user(p_username text, p_password text)
RETURNS json AS $$
DECLARE
  v_user record;
  v_hash text;
BEGIN
  v_hash := encode(digest('ganti-teks-rahasia-ini' || p_password, 'sha256'), 'hex');
  
  SELECT * INTO v_user
  FROM app_users
  WHERE lower(trim(username)) = lower(trim(p_username));

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'message', 'Username atau password salah.');
  END IF;

  IF v_user.password_hash != v_hash AND v_user.password_hash != p_password THEN
    RETURN json_build_object('ok', false, 'message', 'Username atau password salah.');
  END IF;

  IF v_user.role = 'OPD' AND v_user.status = 'Menunggu' THEN
    RETURN json_build_object('ok', false, 'message', 'Akun Anda menunggu persetujuan Tim Konsolidasi.');
  END IF;

  IF v_user.role = 'OPD' AND v_user.status != 'Aktif' THEN
    RETURN json_build_object('ok', false, 'message', 'Akun Anda tidak aktif. Hubungi Tim Konsolidasi.');
  END IF;

  RETURN json_build_object(
    'ok', true,
    'username', v_user.username,
    'role', v_user.role,
    'satker', v_user.satker
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 7. SEED DATA REFERENSI
-- ============================================================

INSERT INTO referensi_satker (nama) VALUES
('Badan Kepegawaian dan Pengembangan Sumber Daya Manusia'),
('Badan Kesatuan Bangsa Dan Politik'),
('Badan Penanggulangan Bencana Daerah'),
('Badan Pendapatan Daerah'),
('Badan Pengelolaan Keuangan dan Aset Daerah'),
('Badan Perencanaan Pembangunan Daerah'),
('Badan Riset dan Inovasi Daerah'),
('Bagian Administrasi Pembangunan'),
('Bagian Hukum'),
('Bagian Kesejahteraan Rakyat'),
('Bagian Organisasi'),
('Bagian Pengadaan Barang dan Jasa'),
('Bagian Perekonomian dan Sumber Daya Alam'),
('Bagian Protokol, Komunikasi dan Administrasi Pimpinan'),
('Bagian Tata Pemerintahan'),
('Bagian Umum'),
('Dinas Kebudayaan dan Pariwisata'),
('Dinas Kepemudaan dan Olahraga'),
('Dinas Kependudukan Dan Pencatatan Sipil'),
('Dinas Kesehatan'),
('Dinas Ketahanan Pangan dan Pertanian'),
('Dinas Komunikasi, Informatika, Statistik dan Persandian'),
('Dinas Koperasi Usaha Kecil dan Menengah dan Perindustrian'),
('Dinas Lingkungan Hidup'),
('Dinas Pekerjaan Umum dan Penataan Ruang'),
('Dinas Pemadam Kebakaran'),
('Dinas Pemberdayaan Perempuan dan Pelindungan Anak serta Pengendalian Penduduk dan Keluarga Berencana'),
('Dinas Penanaman Modal dan Pelayanan Terpadu Satu Pintu'),
('Dinas Pendidikan'),
('Dinas Perdagangan'),
('Dinas Perhubungan'),
('Dinas Perpustakaan dan Kearsipan'),
('Dinas Perumahan, dan Kawasan Permukiman serta Pertanahan'),
('Dinas Sosial'),
('Dinas Tenaga Kerja'),
('Inspektorat'),
('Kecamatan Banjarsari'),
('Kecamatan Jebres'),
('Kecamatan Laweyan'),
('Kecamatan Pasarkliwon'),
('Kecamatan Serengan'),
('Kelurahan Baluwarti'),
('Kelurahan Banjarsari'),
('Kelurahan Banyuanyar'),
('Kelurahan Bumi'),
('Kelurahan Danukusuman'),
('Kelurahan Gajahan'),
('Kelurahan Gandekan'),
('Kelurahan Gilingan'),
('Kelurahan Jagalan'),
('Kelurahan Jajar'),
('Kelurahan Jayengan'),
('Kelurahan Jebres'),
('Kelurahan Joglo'),
('Kelurahan Joyosuran'),
('Kelurahan Joyotakan'),
('Kelurahan Kadipiro'),
('Kelurahan Kampung Baru'),
('Kelurahan Karangasem'),
('Kelurahan Kauman'),
('Kelurahan Kedung Lumbu'),
('Kelurahan Kemlayan'),
('Kelurahan Kepatihan Kulon'),
('Kelurahan Kepatihan Wetan'),
('Kelurahan Keprabon'),
('Kelurahan Kerten'),
('Kelurahan Kestalan'),
('Kelurahan Ketelan'),
('Kelurahan Kratonan'),
('Kelurahan Laweyan'),
('Kelurahan Manahan'),
('Kelurahan Mangkubumen'),
('Kelurahan Mojo'),
('Kelurahan Mojosongo'),
('Kelurahan Nusukan'),
('Kelurahan Pajang'),
('Kelurahan Panularan'),
('Kelurahan Pasar Kliwon'),
('Kelurahan Penumping'),
('Kelurahan Pucangsawit'),
('Kelurahan Punggawan'),
('Kelurahan Purwodiningratan'),
('Kelurahan Purwosari'),
('Kelurahan Sangkrah'),
('Kelurahan Semanggi'),
('Kelurahan Serengan'),
('Kelurahan Setabelan'),
('Kelurahan Sewu'),
('Kelurahan Sondakan'),
('Kelurahan Sriwedari'),
('Kelurahan Sudiroprajan'),
('Kelurahan Sumber'),
('Kelurahan Tegalharjo'),
('Kelurahan Timuran'),
('Kelurahan Tipes'),
('Puskesmas Banyuanyar'),
('Puskesmas Gajahan'),
('Puskesmas Gambirsari'),
('Puskesmas Gilingan'),
('Puskesmas Jayengan'),
('Puskesmas Kratonan'),
('Puskesmas Manahan'),
('Puskesmas Ngoresan'),
('Puskesmas Nusukan'),
('Puskesmas Pajang'),
('Puskesmas Penumping'),
('Puskesmas Pucangsawit'),
('Puskesmas Purwodiningratan'),
('Puskesmas Purwosari'),
('Puskesmas Sangkrah'),
('Puskesmas Setabelan'),
('Puskesmas Sibela'),
('RSUD Bung Karno'),
('RSUD Ibu Fatmawati Soekarno'),
('Satuan Polisi Pamong Praja'),
('Sekretariat Daerah'),
('Sekretariat Dewan Perwakilan Rakyat Daerah'),
('SMP Khusus Olahraga Surakarta'),
('SMP Negeri 1 Kota Surakarta'),
('SMP Negeri 10 Kota Surakarta'),
('SMP Negeri 11 Kota Surakarta'),
('SMP Negeri 12 Kota Surakarta'),
('SMP Negeri 13 Kota Surakarta'),
('SMP Negeri 14 Kota Surakarta'),
('SMP Negeri 15 Kota Surakarta'),
('SMP Negeri 16 Kota Surakarta'),
('SMP Negeri 17 Kota Surakarta'),
('SMP Negeri 18 Kota Surakarta'),
('SMP Negeri 19 Kota Surakarta'),
('SMP Negeri 2 Kota Surakarta'),
('SMP Negeri 20 Kota Surakarta'),
('SMP Negeri 21 Kota Surakarta'),
('SMP Negeri 22 Kota Surakarta'),
('SMP Negeri 23 Kota Surakarta'),
('SMP Negeri 24 Kota Surakarta'),
('SMP Negeri 25 Kota Surakarta'),
('SMP Negeri 26 Kota Surakarta'),
('SMP Negeri 27 Kota Surakarta'),
('SMP Negeri 3 Kota Surakarta'),
('SMP Negeri 4 Kota Surakarta'),
('SMP Negeri 5 Kota Surakarta'),
('SMP Negeri 6 Kota Surakarta'),
('SMP Negeri 7 Kota Surakarta'),
('SMP Negeri 8 Kota Surakarta'),
('SMP Negeri 9 Kota Surakarta'),
('UPTD Aneka Usaha Perikanan pada Dinas Ketahanan Pangan dan Pertanian'),
('UPTD Instalasi Farmasi pada Dinas Kesehatan'),
('UPTD Kawasan Sains Dan Teknologi'),
('UPTD Kawasan Wisata pada Dinas Kebudayaan dan Pariwisata'),
('UPTD Laboratorium Kesehatan pada Dinas Kesehatan'),
('UPTD Metrologi Legal pada Dinas Perdagangan'),
('UPTD Museum pada Dinas Kebudayaan dan Pariwisata'),
('UPTD Pengelolaan Aset Daerah pada Badan Pengelolaan Keuangan dan Aset Daerah'),
('UPTD Pengelolaan Perparkiran pada Dinas Perhubungan'),
('UPTD Pengelolaan Sentra Industri Kecil Menengah'),
('UPTD Pengelolaan Tempat Pemrosesan Akhir Sampah pada Dinas Lingkungan Hidup'),
('UPTD Perlindungan Perempuan dan Anak pada Dinas Pemberdayaan Perempuan dan Pelindungan Anak serta Pengendalian Penduduk dan Keluarga Berencana'),
('UPTD Pusat Layanan Disabilitas dan Pendidikan Inklusif pada Dinas Pendidikan'),
('UPTD Rumah Potong Hewan dan Pusat Kesehatan Hewan pada Dinas Ketahanan Pangan dan Pertanian'),
('UPTD Rumah Sewa pada Dinas Perumahan, dan Kawasan Permukiman serta Pertanahan'),
('UPTD Transportasi pada Dinas Perhubungan')
ON CONFLICT (nama) DO NOTHING;

INSERT INTO referensi_jenis_tenaga (nama) VALUES
('Tenaga Kebersihan Fasilitas Olahraga/Objek Wisata'),
('Tenaga Kebersihan Gedung Kantor'),
('Tenaga Kebersihan Pertamanan Kota'),
('Tenaga Kebersihan Persampahan Kota'),
('Tenaga Kebersihan Lingkungan Kelurahan'),
('Tenaga Keamanan - Anggota'),
('Tenaga Keamanan - Ketua Regu'),
('Tenaga Pengemudi Kendaraan Berat < 3500 Kg'),
('Tenaga Pengemudi Kendaraan Berat ≥ 3500 Kg')
ON CONFLICT (nama) DO NOTHING;

INSERT INTO referensi_penyedia (nama) VALUES
('PERUMDA PAU PEDARINGAN KOTA SURAKARTA'),
('PT ARZATAMA SENTOSA ABADI'),
('PT BINTANG MITRA PRATAMA'),
('PT BRADDA SOLO INDO'),
('PT CAKRAWALA KARUNIA SENTOSA'),
('PT CEMPAKA KARUNIA UTAMA'),
('PT DELTA ALFA RUKUN SEJAHTERA'),
('PT DEVASTU TIRTA NAWASENA'),
('PT FADIYA KENCANA MULYA'),
('PT INTEGRITAS TATA INSANI'),
('PT INTENS WIRA SEMBADA'),
('PT INTI SARANA WIJAYA'),
('PT INVESTAMA KOMANDO SECURITY'),
('PT JAYA WIRA MANGGALA'),
('PT KARUNIA MEKAR SEJATI'),
('PT LANTAR ABYUDAYA PERKASA'),
('PT LUVINA PADMA PERSADA'),
('PT MEGA DAYA REKSA ABADI'),
('PT MUHANDAS PERMATA SARANA'),
('PT SENAPATI WIJAYA ABADI'),
('PT WIDORO KANDANG')
ON CONFLICT (nama) DO NOTHING;

-- Akun Pengguna Awal
INSERT INTO app_users (username, password_hash, role, satker, status) VALUES
('konsolidasi', encode(digest('ganti-teks-rahasia-ini' || 'tim123', 'sha256'), 'hex'), 'Tim Konsolidasi', 'Sekretariat Daerah', 'Aktif'),
('admin', encode(digest('ganti-teks-rahasia-ini' || 'admin123', 'sha256'), 'hex'), 'Tim Konsolidasi', 'Sekretariat Daerah', 'Aktif'),
('satker1', encode(digest('ganti-teks-rahasia-ini' || 'satker123', 'sha256'), 'hex'), 'OPD', 'Sekretariat Daerah', 'Aktif'),
('Dinas Kesehatan', encode(digest('ganti-teks-rahasia-ini' || 'opd123', 'sha256'), 'hex'), 'OPD', 'Dinas Kesehatan', 'Aktif'),
('Dinas Pendidikan', encode(digest('ganti-teks-rahasia-ini' || 'opd123', 'sha256'), 'hex'), 'OPD', 'Dinas Pendidikan', 'Aktif')
ON CONFLICT (username) DO NOTHING;

-- 8. ROW LEVEL SECURITY (RLS) & PUBLIC GRANTS
-- Izinkan anon key membaca dan menulis data sesuai aturan aplikasi
ALTER TABLE referensi_satker ENABLE ROW LEVEL SECURITY;
ALTER TABLE referensi_jenis_tenaga ENABLE ROW LEVEL SECURITY;
ALTER TABLE referensi_penyedia ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE pengajuan ENABLE ROW LEVEL SECURITY;
ALTER TABLE klarifikasi ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public Read Referensi Satker" ON referensi_satker FOR SELECT USING (true);
CREATE POLICY "Public Read Referensi Jenis" ON referensi_jenis_tenaga FOR SELECT USING (true);
CREATE POLICY "Public Read Referensi Penyedia" ON referensi_penyedia FOR SELECT USING (true);

CREATE POLICY "Public Read Users" ON app_users FOR SELECT USING (true);
CREATE POLICY "Public Insert Users" ON app_users FOR INSERT WITH CHECK (true);
CREATE POLICY "Public Update Users" ON app_users FOR UPDATE USING (true);

CREATE POLICY "Public Read Pengajuan" ON pengajuan FOR SELECT USING (true);
CREATE POLICY "Public Insert Pengajuan" ON pengajuan FOR INSERT WITH CHECK (true);
CREATE POLICY "Public Update Pengajuan" ON pengajuan FOR UPDATE USING (true);

CREATE POLICY "Public Read Klarifikasi" ON klarifikasi FOR SELECT USING (true);
CREATE POLICY "Public Insert Klarifikasi" ON klarifikasi FOR INSERT WITH CHECK (true);

-- ============================================================
-- 9. SUPABASE STORAGE (BUCKET & RLS POLICIES)
-- ============================================================

-- Pastikan bucket 'dokumen-pengajuan' ada dan bersifat publik
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokumen-pengajuan', 'dokumen-pengajuan', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Bersihkan policy lama jika ada
DROP POLICY IF EXISTS "Public Upload Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Select Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Update Dokumen" ON storage.objects;
DROP POLICY IF EXISTS "Public Delete Dokumen" ON storage.objects;

-- Beri izin penuh kepada public/anon untuk mengunggah, membaca, memperbarui, dan menghapus dokumen di bucket 'dokumen-pengajuan'
CREATE POLICY "Public Upload Dokumen"
ON storage.objects FOR INSERT
TO public
WITH CHECK (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Public Select Dokumen"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Public Update Dokumen"
ON storage.objects FOR UPDATE
TO public
USING (bucket_id = 'dokumen-pengajuan');

CREATE POLICY "Public Delete Dokumen"
ON storage.objects FOR DELETE
TO public
USING (bucket_id = 'dokumen-pengajuan');
