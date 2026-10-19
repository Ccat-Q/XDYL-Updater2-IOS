import { base64, fail, secret, sequence } from './common.js';
const encode = bytes => base64(bytes).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
function decode(s) {
  if (!/^[A-Za-z0-9_-]+$/.test(s)) fail(400, 'INVALID_CURSOR');
  try { return Uint8Array.from(atob(s.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - s.length % 4) % 4)), c => c.charCodeAt(0)); }
  catch { fail(400, 'INVALID_CURSOR'); }
}
async function key(env) {
  return crypto.subtle.importKey('raw', secret(env, 'CURSOR_SECRET'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
export async function signCursor(env, auth, position, floor) {
  return signOpaque(env, { v: 2, s: auth.subject, d: auth.device_id, p: position, f: floor });
}
export async function signOpaque(env, value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return `${encode(bytes)}.${encode(await crypto.subtle.sign('HMAC', await key(env), bytes))}`;
}
export async function readOpaque(env, raw) {
  if (!raw || raw.length > 2048) fail(400, 'INVALID_CURSOR');
  const parts = raw.split('.'); if (parts.length !== 2) fail(400, 'INVALID_CURSOR');
  const bytes = decode(parts[0]);
  if (!await crypto.subtle.verify('HMAC', await key(env), decode(parts[1]), bytes)) fail(400, 'INVALID_CURSOR');
  let p; try { p = JSON.parse(new TextDecoder().decode(bytes)); } catch { fail(400, 'INVALID_CURSOR'); }
  return p;
}
export async function parseCursor(env, auth, raw) {
  const p = await readOpaque(env, raw);
  if (p.v !== 2 || p.s !== auth.subject || p.d !== auth.device_id) fail(403, 'FORBIDDEN');
  sequence(p.p); sequence(p.f);
  return p;
}
