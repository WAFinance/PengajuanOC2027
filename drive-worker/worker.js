/**
 * Cloudflare Worker — perantara Google Drive untuk aplikasi Pengajuan.
 *
 * Alur upload  : browser -> POST /upload-session (Worker cek login Firebase, minta sesi ke Drive)
 *                browser -> PUT langsung ke URL sesi Drive (file TIDAK lewat Worker)
 * Alur unduh   : browser -> GET /file?id=...  (Worker cek login, ambil dari Drive, teruskan)
 * Alur bersih  : browser -> DELETE /file?id=... (hanya pemilik unggahan, untuk membatalkan pengajuan gagal)
 *
 * Secret  : GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
 * Variabel: FIREBASE_PROJECT_ID, ALLOWED_ORIGINS (pisahkan dengan koma),
 *           DRIVE_FOLDER_ID (opsional; kalau kosong, folder dicari/dibuat otomatis)
 */

const ALLOWED_EXT = ['pdf', 'doc', 'docx', 'xls', 'xlsx'];
const MAX_BYTES = 10 * 1024 * 1024;
const FOLDER_NAME = 'Pengajuan OC 2027 - Dokumen';
const JWK_URL = 'https://www.googleapis.com/robot/v1/metadata/jwk/securetoken@system.gserviceaccount.com';

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// Cache per isolate (bertahan selama Worker hangat)
let tokenCache = { value: null, exp: 0 };
let folderCache = null;
let jwkCache = { keys: null, exp: 0 };

/* ---------------------------- CORS & helper ---------------------------- */
function corsInfo(request, env) {
  const origin = request.headers.get('Origin') || '';
  const allowed = (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
  const ok = allowed.includes(origin);
  return {
    ok, origin,
    headers: {
      'Access-Control-Allow-Origin': ok ? origin : (allowed[0] || ''),
      'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization,Content-Type',
      'Access-Control-Max-Age': '86400',
      'Vary': 'Origin'
    }
  };
}

function json(obj, status, headers) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, headers || {})
  });
}

const b64uToBytes = s => {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), ch => ch.charCodeAt(0));
};
const b64uToJson = s => JSON.parse(new TextDecoder().decode(b64uToBytes(s)));

/* ------------------------ Verifikasi Firebase ID token ------------------------ */
async function getJwks() {
  const now = Date.now();
  if (jwkCache.keys && jwkCache.exp > now) return jwkCache.keys;
  const r = await fetch(JWK_URL);
  if (!r.ok) throw new HttpError(502, 'Gagal mengambil kunci verifikasi login.');
  const j = await r.json();
  jwkCache = { keys: j.keys || [], exp: now + 60 * 60 * 1000 };
  return jwkCache.keys;
}

async function verifyFirebaseToken(request, env) {
  const h = request.headers.get('Authorization') || '';
  const jwt = h.startsWith('Bearer ') ? h.slice(7).trim() : '';
  const parts = jwt.split('.');
  if (parts.length !== 3) throw new HttpError(401, 'Anda belum login.');

  let header, payload;
  try { header = b64uToJson(parts[0]); payload = b64uToJson(parts[1]); }
  catch (e) { throw new HttpError(401, 'Token login tidak valid.'); }

  const pid = env.FIREBASE_PROJECT_ID;
  const now = Math.floor(Date.now() / 1000);
  if (header.alg !== 'RS256' ||
      payload.aud !== pid ||
      payload.iss !== 'https://securetoken.google.com/' + pid ||
      !payload.sub || typeof payload.exp !== 'number' ||
      payload.exp < now || (payload.iat || 0) > now + 300) {
    throw new HttpError(401, 'Sesi login tidak valid atau sudah berakhir.');
  }

  const keys = await getJwks();
  const jwk = keys.find(k => k.kid === header.kid);
  if (!jwk) throw new HttpError(401, 'Token login tidak dikenali.');

  const key = await crypto.subtle.importKey(
    'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5', key, b64uToBytes(parts[2]),
    new TextEncoder().encode(parts[0] + '.' + parts[1]));
  if (!valid) throw new HttpError(401, 'Tanda tangan token tidak valid.');
  return payload; // payload.sub = uid Firebase
}

/* ------------------------------ Google Drive ------------------------------ */
async function driveToken(env) {
  const now = Date.now();
  if (tokenCache.value && tokenCache.exp > now + 60000) return tokenCache.value;
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      refresh_token: env.GOOGLE_REFRESH_TOKEN,
      grant_type: 'refresh_token'
    })
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) {
    console.error('Refresh token gagal:', JSON.stringify(j));
    throw new HttpError(502, 'Layanan Drive belum dapat diakses. Kode dari Google: ' + (j.error || r.status) + '. Periksa kredensial Worker.');
  }
  tokenCache = { value: j.access_token, exp: now + (j.expires_in || 3600) * 1000 };
  return j.access_token;
}

async function rootFolder(env, at) {
  if (env.DRIVE_FOLDER_ID) return env.DRIVE_FOLDER_ID;
  if (folderCache) return folderCache;
  const auth = { Authorization: 'Bearer ' + at };
  const q = encodeURIComponent("name='" + FOLDER_NAME + "' and mimeType='application/vnd.google-apps.folder' and trashed=false");
  let r = await fetch('https://www.googleapis.com/drive/v3/files?q=' + q + '&fields=files(id)&pageSize=1', { headers: auth });
  let j = await r.json().catch(() => ({}));
  if (!r.ok) throw new HttpError(502, 'Gagal membaca folder Drive.');
  if (j.files && j.files.length) return (folderCache = j.files[0].id);

  r = await fetch('https://www.googleapis.com/drive/v3/files?fields=id', {
    method: 'POST',
    headers: Object.assign({ 'Content-Type': 'application/json' }, auth),
    body: JSON.stringify({ name: FOLDER_NAME, mimeType: 'application/vnd.google-apps.folder' })
  });
  j = await r.json().catch(() => ({}));
  if (!r.ok || !j.id) throw new HttpError(502, 'Gagal membuat folder Drive.');
  return (folderCache = j.id);
}

/* ------------------------------- Endpoint ------------------------------- */
async function buatSesi(request, env, user, c) {
  let b;
  try { b = await request.json(); } catch (e) { throw new HttpError(400, 'Permintaan tidak valid.'); }

  const nama = String(b.name || 'dokumen').replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120);
  const ext = nama.split('.').pop().toLowerCase();
  const size = Number(b.size);
  const id = String(b.id || '');
  const jenis = String(b.jenis || '');

  if (ALLOWED_EXT.indexOf(ext) < 0) throw new HttpError(400, 'Format harus PDF, DOC, DOCX, XLS, atau XLSX.');
  if (!(size > 0) || size > MAX_BYTES) throw new HttpError(400, 'Ukuran berkas harus 1 byte sampai 10 MB.');
  if (!/^PGJ-\d{8}-\d{4}$/.test(id)) throw new HttpError(400, 'ID pengajuan tidak valid.');
  if (!/^[a-z]{2,12}$/.test(jenis)) throw new HttpError(400, 'Jenis dokumen tidak valid.');
  const mime = /^[\w.+-]+\/[\w.+-]+$/.test(String(b.mime || '')) ? b.mime : 'application/octet-stream';

  const at = await driveToken(env);
  const parent = await rootFolder(env, at);

  const r = await fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name,size', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + at,
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Upload-Content-Type': mime,
      'X-Upload-Content-Length': String(size),
      // Origin memberi izin CORS pada URL sesi, sehingga browser bisa PUT langsung ke Drive
      'Origin': c.origin
    },
    body: JSON.stringify({
      name: id + '_' + jenis + '_' + Date.now() + '_' + nama,
      parents: [parent],
      appProperties: { pengajuanId: id, jenis: jenis, uid: user.sub }
    })
  });
  const loc = r.headers.get('Location');
  if (!r.ok || !loc) {
    console.error('Buat sesi gagal:', r.status, await r.text().catch(() => ''));
    throw new HttpError(502, 'Drive menolak membuat sesi unggah.');
  }
  return json({ ok: true, uploadUrl: loc }, 200, c.headers);
}

async function ambilBerkas(env, id, c) {
  const at = await driveToken(env);
  const r = await fetch('https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(id) + '?alt=media', {
    headers: { Authorization: 'Bearer ' + at }
  });
  if (!r.ok) throw new HttpError(r.status === 404 ? 404 : 502, 'Berkas tidak ditemukan di Drive.');
  return new Response(r.body, {
    status: 200,
    headers: Object.assign({
      'Content-Type': r.headers.get('Content-Type') || 'application/octet-stream',
      'Cache-Control': 'private, no-store'
    }, c.headers)
  });
}

async function hapusBerkas(env, id, user, c) {
  const at = await driveToken(env);
  const auth = { Authorization: 'Bearer ' + at };
  const url = 'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(id);

  const m = await fetch(url + '?fields=appProperties', { headers: auth });
  if (!m.ok) throw new HttpError(404, 'Berkas tidak ditemukan.');
  const meta = await m.json().catch(() => ({}));
  if (!meta.appProperties || meta.appProperties.uid !== user.sub) {
    throw new HttpError(403, 'Hanya pengunggah yang dapat membatalkan berkas ini.');
  }
  // Dipindah ke sampah (bukan hapus permanen) agar masih bisa dipulihkan
  const d = await fetch(url, {
    method: 'PATCH',
    headers: Object.assign({ 'Content-Type': 'application/json' }, auth),
    body: JSON.stringify({ trashed: true })
  });
  if (!d.ok) throw new HttpError(502, 'Gagal menghapus berkas.');
  return json({ ok: true }, 200, c.headers);
}

/* -------------------------------- Router -------------------------------- */
export default {
  async fetch(request, env) {
    const c = corsInfo(request, env);
    // Pemeriksaan konfigurasi (tanpa login, hanya menampilkan ada/tidaknya nilai, bukan isinya)
    if (request.method === 'GET' && new URL(request.url).pathname === '/health') {
      return json({
        ok: true,
        ALLOWED_ORIGINS_terisi: (env.ALLOWED_ORIGINS || '').split(',').filter(s => s.trim()).length,
        FIREBASE_PROJECT_ID: !!env.FIREBASE_PROJECT_ID,
        GOOGLE_CLIENT_ID: !!env.GOOGLE_CLIENT_ID,
        GOOGLE_CLIENT_SECRET: !!env.GOOGLE_CLIENT_SECRET,
        GOOGLE_REFRESH_TOKEN: !!env.GOOGLE_REFRESH_TOKEN
      });
    }
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: c.ok ? 204 : 403, headers: c.headers });
    }
    try {
      if (!c.ok) throw new HttpError(403, 'Origin tidak diizinkan.');
      const url = new URL(request.url);
      const user = await verifyFirebaseToken(request, env);

      if (request.method === 'POST' && url.pathname === '/upload-session') {
        return await buatSesi(request, env, user, c);
      }
      if (url.pathname === '/file') {
        const id = url.searchParams.get('id') || '';
        if (!/^[A-Za-z0-9_-]{10,100}$/.test(id)) throw new HttpError(400, 'ID berkas tidak valid.');
        if (request.method === 'GET') return await ambilBerkas(env, id, c);
        if (request.method === 'DELETE') return await hapusBerkas(env, id, user, c);
      }
      throw new HttpError(404, 'Tidak ditemukan.');
    } catch (e) {
      if (!(e instanceof HttpError)) console.error(e);
      const status = e instanceof HttpError ? e.status : 500;
      return json({ ok: false, message: e instanceof HttpError ? e.message : 'Kesalahan server.' }, status, c.headers);
    }
  }
};