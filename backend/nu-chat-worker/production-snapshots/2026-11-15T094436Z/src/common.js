export const AUTH_URL = 'https://login.lanternwaves.fun/user/profile';
export const DAY = 86_400_000;
export const MAX_BODY = 524_288;
export class ApiError extends Error {
  constructor(status, code, message = code, headers = {}) {
    super(message); this.status = status; this.code = code; this.headers = headers;
  }
}
export const fail = (status, code) => { throw new ApiError(status, code); };
export function response(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization,Content-Type,X-Chunk-SHA256', ...headers
  } });
}
export function object(value, required, optional = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || required.some(k => !Object.hasOwn(value, k))
      || Object.keys(value).some(k => !required.includes(k) && !optional.includes(k))) fail(400, 'INVALID_REQUEST');
  return value;
}
export function text(value, max = 128) {
  if (typeof value !== 'string' || !value.length || value.length > max) fail(400, 'INVALID_REQUEST');
  return value;
}
export function username(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(value) || value === '.' || value === '..') fail(400, 'INVALID_REQUEST');
  return value;
}
export function uuid(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) fail(400, 'INVALID_REQUEST');
  return value.toLowerCase();
}
export function sequence(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,18})$/.test(value)
      || BigInt(value) > 9223372036854775807n) fail(400, 'INVALID_REQUEST');
  return value;
}
export function query(url, allowed) {
  const seen = new Set();
  for (const [key] of url.searchParams) {
    if (!allowed.includes(key) || seen.has(key)) fail(400, 'INVALID_REQUEST');
    seen.add(key);
  }
}
export async function body(req) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers.get('Content-Type') || '')) fail(415, 'INVALID_REQUEST');
  const reader = req.body?.getReader();
  if (!reader) fail(400, 'INVALID_REQUEST');
  const chunks = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > MAX_BODY) { await reader.cancel(); fail(413, 'PAYLOAD_TOO_LARGE'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { fail(400, 'INVALID_REQUEST'); }
}
export async function noBody(req) {
  if (req.body) {
    const r = req.body.getReader();
    try { const v = await r.read(); if (!v.done) { await r.cancel(); fail(400, 'INVALID_REQUEST'); } }
    finally { r.releaseLock(); }
  }
}
export function bearer(req) {
  const h = req.headers.get('Authorization') || '';
  if (h.length > 8192 || !/^Bearer [^\s,]+$/i.test(h)) fail(401, 'UNAUTHORIZED');
  return h.slice(7);
}
export async function mainIdentity(req, fetcher) {
  const token = bearer(req); let r, j;
  try {
    r = await fetcher(AUTH_URL, { headers: { Authorization: `Bearer ${token}`, 'User-Agent': 'NU-Chat/3.0' },
      redirect: 'manual', signal: AbortSignal.timeout(8000) });
    if (r.status === 401 || r.status === 403) fail(401, 'UNAUTHORIZED');
    if (!r.ok) fail(503, 'TEMPORARILY_UNAVAILABLE');
    j = await r.json();
  } catch (e) { if (e instanceof ApiError) throw e; fail(503, 'TEMPORARILY_UNAVAILABLE'); }
  if (j?.code !== undefined) {
    const code = Number(j.code);
    if (code === 401 || code === 403) fail(401, 'UNAUTHORIZED');
    if (!Number.isInteger(code) || code < 200 || code >= 300) fail(503, 'TEMPORARILY_UNAVAILABLE');
  }
  const d = j?.data ?? j;
  if (!d || typeof d.username !== 'string') fail(409, 'IDENTITY_UNSUPPORTED');
  if (d.banned === true || d.banned === 1 || d.banned === '1' || d.disabled === true) fail(403, 'FORBIDDEN');
  return { username: username(d.username), id: d.id ?? d.user_id };
}
export function subject(identity) {
  const id = identity.id;
  if ((typeof id === 'number' && Number.isSafeInteger(id) && id > 0)
      || (typeof id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(id) && id !== '0')) return `account:${id}`;
  fail(409, 'IDENTITY_UNSUPPORTED');
}
export function base64(bytes) { return btoa(String.fromCharCode(...new Uint8Array(bytes))); }
export function unbase64(value, max = 32768) {
  if (typeof value !== 'string' || !value.length || value.length > max * 1.4 + 4
      || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) fail(400, 'INVALID_REQUEST');
  let bytes;
  try { bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
  catch { fail(400, 'INVALID_REQUEST'); }
  if (bytes.length > max || base64(bytes) !== value) fail(400, 'INVALID_REQUEST');
  return bytes;
}
export async function publicKey(algorithm, value) {
  const bytes = unbase64(value, 1024);
  const spec = algorithm === 'X25519' ? { name: 'X25519' }
    : algorithm === 'P256' ? { name: 'ECDH', namedCurve: 'P-256' } : null;
  if (!spec) fail(400, 'UNSUPPORTED_ALGORITHM');
  // workerd and Node do not reject every mismatched SPKI identically. Check
  // the canonical algorithm OID/curve and bit-string length before importing,
  // otherwise a P-256 legacy peer can be mistakenly labelled X25519.
  const prefix=algorithm==='X25519'?[0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x6e,0x03,0x21,0x00]
    :[0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00,0x04];
  if(bytes.length!==(algorithm==='X25519'?44:91)||prefix.some((b,i)=>bytes[i]!==b))fail(400,'INVALID_REQUEST');
  try { await crypto.subtle.importKey('spki', bytes, spec, false, []); }
  catch { fail(400, 'INVALID_REQUEST'); }
}
export const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]`
  : value !== null && typeof value === 'object' ? `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`
  : JSON.stringify(value);
export async function hash(value) {
  return base64(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
}
export function secret(env, name) {
  const raw = env[name];
  if (typeof raw !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(raw)) fail(503, 'NOT_CONFIGURED');
  const key = unbase64(raw, 32);
  if (key.length !== 32) fail(503, 'NOT_CONFIGURED');
  return key;
}
export const statement = (db, sql, ...args) => db.prepare(sql).bind(...args);
export const rows = async stmt => (await stmt.all()).results;
export function guard(db, sql, ...args) {
  return statement(db, `UPDATE v2_guard SET valid=CASE WHEN (${sql}) THEN 1 ELSE 0 END WHERE id=1`, ...args);
}
export async function atomic(db, statements, code = 'REVISION_CONFLICT') {
  try { return await db.batch(statements); }
  catch (e) {
    if (/CHECK constraint failed|UNIQUE constraint failed|FOREIGN KEY constraint failed/i.test(String(e))) fail(409, code);
    throw e;
  }
}
export async function rate(db, scope, max, now) {
  const window = Math.floor(now / 60000);
  const r = await statement(db, `INSERT INTO v2_rate_limits(scope,window,count) VALUES(?,?,1)
    ON CONFLICT(scope) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END,
    window=excluded.window RETURNING count`, scope, window).first();
  if (r.count > max) throw new ApiError(429, 'RATE_LIMITED', 'RATE_LIMITED', { 'Retry-After': String(60 - Math.floor(now / 1000) % 60) });
}
