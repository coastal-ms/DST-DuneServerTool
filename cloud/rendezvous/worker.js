// DST Rendezvous Worker
// =====================
//
// A tiny, stateless-by-design address book that lets the DST mobile app find a
// home server whose public address keeps changing (the free Cloudflare quick
// tunnel hands out a new *.trycloudflare.com URL every time it restarts).
//
// It maps a stable, random PAIRING ID -> the server's CURRENT tunnel URL.
// That is ALL it stores. It deliberately holds NO DST credentials:
//
//   * The host publishes only its current URL (never the DuneToken / remote
//     token). A leaked or compromised rendezvous therefore exposes only a URL,
//     which is useless on its own — DST still rejects every /api/* call that
//     lacks the per-server remote token (delivered to the phone out-of-band via
//     the pairing QR, never through here).
//   * Writes are authorized by a per-pairing publishKey chosen by the host on
//     first publish (first-writer-wins binds id -> sha256(publishKey)). Only
//     the SHA-256 hash is stored, so the Worker can authorize updates without
//     ever holding the secret. This stops anyone who guesses an id from
//     hijacking where it points.
//   * Reads (GET /r/:id) are unauthenticated: knowing the (128-bit random) id
//     is enough to learn the URL, and the URL alone grants nothing.
//
// Endpoints:
//   POST /publish   { id, publishKey, url }      -> { ok: true, updatedAt }
//   GET  /r/:id                                  -> { url, updatedAt } | 404
//   GET  /                                       -> health text
//
// Binding: KV namespace `RENDEZVOUS` (key `pair:<id>`).

const PAIR_TTL_SECONDS = 60 * 60 * 24 * 30; // refresh-or-expire after 30 days idle
const MAX_URL_LEN = 512;
const ID_RE = /^[A-Za-z0-9_-]{16,64}$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    },
  });
}

async function sha256Hex(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Constant-time-ish compare to avoid leaking the hash via timing.
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function isValidUrl(u) {
  if (typeof u !== 'string' || u.length === 0 || u.length > MAX_URL_LEN) return false;
  try {
    const parsed = new URL(u);
    return parsed.protocol === 'https:' || parsed.protocol === 'http:';
  } catch {
    return false;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET,POST,OPTIONS',
          'access-control-allow-headers': 'content-type',
        },
      });
    }

    if (pathname === '/' && request.method === 'GET') {
      return new Response('DST rendezvous OK', {
        status: 200,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }

    // GET /r/:id  -> resolve current URL
    if (request.method === 'GET' && pathname.startsWith('/r/')) {
      const id = decodeURIComponent(pathname.slice(3));
      if (!ID_RE.test(id)) return json({ error: 'bad id' }, 400);
      const raw = await env.RENDEZVOUS.get(`pair:${id}`);
      if (!raw) return json({ error: 'not found' }, 404);
      let rec;
      try { rec = JSON.parse(raw); } catch { return json({ error: 'corrupt' }, 500); }
      return json({ url: rec.url, updatedAt: rec.updatedAt });
    }

    // POST /publish  { id, publishKey, url }
    if (request.method === 'POST' && pathname === '/publish') {
      let body;
      try { body = await request.json(); } catch { return json({ error: 'bad json' }, 400); }
      const id = body && body.id;
      const publishKey = body && body.publishKey;
      const newUrl = body && body.url;

      if (!ID_RE.test(id || '')) return json({ error: 'bad id' }, 400);
      if (typeof publishKey !== 'string' || publishKey.length < 16 || publishKey.length > 256) {
        return json({ error: 'bad publishKey' }, 400);
      }
      if (!isValidUrl(newUrl)) return json({ error: 'bad url' }, 400);

      const keyHash = await sha256Hex(publishKey);
      const existingRaw = await env.RENDEZVOUS.get(`pair:${id}`);
      if (existingRaw) {
        let existing;
        try { existing = JSON.parse(existingRaw); } catch { existing = null; }
        if (existing && existing.publishKeyHash && !timingSafeEqual(existing.publishKeyHash, keyHash)) {
          // id already owned by a different publishKey — refuse to hijack.
          return json({ error: 'forbidden' }, 403);
        }
      }

      const updatedAt = new Date().toISOString();
      const rec = { url: newUrl, updatedAt, publishKeyHash: keyHash };
      await env.RENDEZVOUS.put(`pair:${id}`, JSON.stringify(rec), { expirationTtl: PAIR_TTL_SECONDS });
      return json({ ok: true, updatedAt });
    }

    return json({ error: 'not found' }, 404);
  },
};
