import { fail, object, body, noBody, uuid, query, text, base64, unbase64, secret,
  statement as q, rows, atomic, rate, sequence, guard, DAY } from './common.js';
import { sessionGuard } from './store.js';
import { notificationEligibility } from './notifications.js';

export function barkEnabled(env) {
  if (env.BARK_ENABLED !== 'true') return false;
  try { secret(env, 'BARK_ENCRYPTION_KEY'); return true; } catch { return false; }
}
export function barkOrigin(raw, env) {
  text(raw, 256); let u;
  try { u = new URL(raw); } catch { fail(400, 'INVALID_REQUEST'); }
  if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash
      || (u.pathname !== '' && u.pathname !== '/') || u.port || raw.includes('\\')) fail(400, 'INVALID_REQUEST');
  const origin = u.origin;
  if (origin !== 'https://api.day.app') fail(400, 'BARK_ORIGIN_NOT_ALLOWED');
  return origin;
}
async function aes(env) {
  return crypto.subtle.importKey('raw', secret(env, 'BARK_ENCRYPTION_KEY'), 'AES-GCM', false, ['encrypt', 'decrypt']);
}
function bindingAAD(device, origin, version) { return new TextEncoder().encode(JSON.stringify([device, origin, version])); }
async function encryptKey(env, device, origin, version, key) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce,
    additionalData: bindingAAD(device, origin, version) }, await aes(env), new TextEncoder().encode(key));
  return `${base64(nonce)}:${base64(cipher)}`;
}
async function decryptKey(env, row) {
  const [nonce, cipher] = row.encrypted_key.split(':');
  const data = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unbase64(nonce, 12),
    additionalData: bindingAAD(row.device_id, row.server_url, row.version) }, await aes(env), unbase64(cipher, 2048));
  return new TextDecoder().decode(data);
}
export async function barkRoute(req, env, db, url, auth, deps) {
  if (!barkEnabled(env)) fail(503, 'BARK_NOT_CONFIGURED');
  query(url, req.method==='DELETE'?['expected_revision']:[]);
  const m = url.pathname.match(/^\/chat\/v2\/devices\/([^/]+)\/bark(?:\/(test|status))?$/);
  const id = uuid(m[1]); if (id !== auth.device_id) fail(403, 'FORBIDDEN');
  const now = deps.now(); const sg = sessionGuard(db, auth, now);
  if (!m[2] && req.method === 'GET') {
    await noBody(req);
    const row=await q(db,'SELECT * FROM v2_bark WHERE device_id=?',id).first();
    return {ok:true,data:{server_url:'https://api.day.app',enabled:!!row?.enabled,key_configured:!!row,
      device_key_masked:row?`••••${(await decryptKey(env,row)).slice(-4)}`:null,revision:String(row?.revision??0)}};
  }
  if (!m[2] && req.method === 'PUT') {
    const b = object(await body(req), ['enabled'],['server_url','device_key','expected_revision']);
    if (typeof b.enabled !== 'boolean') fail(400,'INVALID_REQUEST');
    const old=await q(db,'SELECT * FROM v2_bark WHERE device_id=?',id).first();
    if(old&&b.expected_revision===undefined) fail(428,'PRECONDITION_REQUIRED');
    const revision=sequence(b.expected_revision??'0');
    const deviceKey=b.device_key??(old?await decryptKey(env,old):null);
    if (!/^[A-Za-z0-9_-]{1,512}$/.test(text(deviceKey, 512))) fail(400, 'INVALID_REQUEST');
    const origin = barkOrigin(b.server_url??'https://api.day.app', env); const version = crypto.randomUUID();
    const ciphertext = await encryptKey(env, id, origin, version, deviceKey);
    await atomic(db, [sg,
      guard(db,'COALESCE((SELECT revision FROM v2_bark WHERE device_id=?),0)=CAST(? AS INTEGER)',id,revision),
      q(db, "UPDATE v2_outbox SET state='cancelled',lease_token=NULL,lease_until=0 WHERE device_id=? AND state IN ('queued','leased')", id),
      q(db, `INSERT INTO v2_bark(device_id,server_url,encrypted_key,version,enabled) VALUES(?,?,?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET server_url=excluded.server_url,encrypted_key=excluded.encrypted_key,
        version=excluded.version,enabled=excluded.enabled,revision=revision+1,last_result='none',last_error=NULL,last_attempt=NULL`, id, origin, ciphertext, version, b.enabled ? 1 : 0)]);
    return { ok: true, data: { enabled: b.enabled, server_url: origin, preview: 'generic',revision:String(BigInt(revision)+1n) } };
  }
  if (!m[2] && req.method === 'DELETE') {
    await noBody(req);
    const existing=await q(db,'SELECT revision FROM v2_bark WHERE device_id=?',id).first();
    if(!existing) return {ok:true};
    const revision=sequence(url.searchParams.get('expected_revision'));
    await atomic(db, [sg,guard(db,'EXISTS(SELECT 1 FROM v2_bark WHERE device_id=? AND revision=?)',id,revision),q(db, 'DELETE FROM v2_bark WHERE device_id=?', id),
      q(db, "UPDATE v2_outbox SET state='cancelled',lease_token=NULL,lease_until=0 WHERE device_id=? AND state IN ('queued','leased')", id)]);
    return { ok: true };
  }
  if (m[2] === 'status' && req.method === 'GET') {
    await noBody(req);
    const row = await q(db, 'SELECT enabled,last_attempt,last_result,last_error FROM v2_bark WHERE device_id=?', id).first();
    return { ok: true, data: { enabled: !!row?.enabled, last_attempt_at_ms: row?.last_attempt ?? null,
      last_result: row?.last_result ?? 'none', last_error_code: row?.last_error ?? null } };
  }
  if (m[2] === 'test' && req.method === 'POST') {
    object(await body(req), []); await rate(db, `bark-test:${id}`, 3, now);
    const row = await q(db, 'SELECT version FROM v2_bark WHERE device_id=? AND enabled=1', id).first();
    if (!row) fail(409, 'BARK_NOT_CONFIGURED');
    const notification = crypto.randomUUID();
    await atomic(db, [sg, q(db, `INSERT INTO v2_outbox(notification_id,device_id,binding_version,next_at,created_at)
      SELECT ?,device_id,version,?,? FROM v2_bark WHERE device_id=? AND enabled=1 AND version=?`, notification, now, now, id, row.version),
    q(db, "UPDATE v2_bark SET last_result='queued',last_error=NULL WHERE device_id=? AND version=?", id, row.version)]);
    const job = await q(db, 'SELECT notification_id FROM v2_outbox WHERE notification_id=?', notification).first();
    if (!job) fail(409, 'BARK_NOT_CONFIGURED');
    return { ok: true, data: { queued: true, notification_id: notification } };
  }
  fail(405, 'METHOD_NOT_ALLOWED');
}

// A scheduled trigger resumes durable leases after a worker restart. No secrets
// or upstream response text are ever logged or copied to status/errors.
export async function drainBark(env, db, deps, maximum = 10) {
  if (!barkEnabled(env)) return;
  for (let i = 0; i < maximum; i++) {
    const now = deps.now(); const lease = crypto.randomUUID();
    const job = await q(db, `UPDATE v2_outbox SET state='leased',lease_token=?,lease_until=?,attempts=attempts+1
      WHERE notification_id=(SELECT notification_id FROM v2_outbox
      WHERE state IN ('queued','leased') AND next_at<=? AND lease_until<=? ORDER BY next_at,created_at LIMIT 1)
      RETURNING *`, lease, now + 30000, now, now).first();
    if (!job) return;
    const binding = await q(db, `SELECT b.*,d.revoked FROM v2_bark b JOIN v2_devices d ON d.device_id=b.device_id
      WHERE b.device_id=? AND b.enabled=1 AND b.version=?`, job.device_id, job.binding_version).first();
    const eligibility=await notificationEligibility(db,job,now);
    // Reception is not reading: a background sync must not consume an unread
    // summary. The private read watermark is checked by notificationEligibility.
    if (!binding || binding.revoked || !eligibility.allow || now - job.created_at >= DAY) {
      await db.batch([q(db, "UPDATE v2_outbox SET state='cancelled',lease_until=0 WHERE notification_id=? AND lease_token=?", job.notification_id, lease),
        q(db,'DELETE FROM v2_notification_summaries WHERE notification_id=?',job.notification_id)]); continue;
    }
    if(eligibility.quietUntil>now){
      await q(db,`UPDATE v2_outbox SET state='queued',quiet_summary=1,quiet_until=?,next_at=?,lease_until=0,lease_token=NULL,
        attempts=MAX(attempts-1,0) WHERE notification_id=? AND lease_token=?`,eligibility.quietUntil,eligibility.quietUntil,job.notification_id,lease).run();continue;
    }
    if(job.message_id){
      const end=job.quiet_until||Math.floor(now/10000)*10000+10000;
      await q(db,'INSERT INTO v2_notification_summaries(device_id,window_end,notification_id) VALUES(?,?,?) ON CONFLICT(device_id,window_end) DO NOTHING',job.device_id,end,job.notification_id).run();
      const winner=await q(db,'SELECT notification_id FROM v2_notification_summaries WHERE device_id=? AND window_end=?',job.device_id,end).first();
      if(winner.notification_id!==job.notification_id){await q(db,"UPDATE v2_outbox SET state='cancelled',lease_until=0 WHERE notification_id=? AND lease_token=?",job.notification_id,lease).run();continue;}
      await q(db,'UPDATE v2_outbox SET quiet_until=? WHERE notification_id=? AND lease_token=?',end,job.notification_id,lease).run();
    }
    let result = 'failed'; let error = 'NETWORK_ERROR'; let retry = true; let retryAfter = 0;
    try {
      const origin = barkOrigin(binding.server_url, env);
      const deviceKey = await decryptKey(env, binding);
      const payload = { device_key: deviceKey, title: '星灯云浪',
        body: job.message_id ? (job.quiet_summary?'你有未读私聊，请打开应用查看':'收到新私聊，请打开应用查看') : '私聊提醒测试', group: 'starwave-chat', isArchive: 0 };
      const request = new Request(`${origin}/push`, { method: 'POST', redirect: 'manual',
        signal: AbortSignal.timeout(8000), headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      const r = await deps.fetch(request);
      const ra = r.headers.get('Retry-After');
      if (ra) retryAfter = /^\d+$/.test(ra) ? Number(ra) * 1000 : Math.max(0, Date.parse(ra) - now) || 0;
      if (r.status === 429) error = 'RATE_LIMITED';
      else if (r.status >= 500) error = 'UPSTREAM_REJECTED';
      else if (!r.ok) { error = r.status === 400 || r.status === 401 ? 'INVALID_KEY' : 'UPSTREAM_REJECTED'; retry = false; }
      else {
        const data = await r.json();
        if (data.code === 200) { result = 'accepted'; error = null; retry = false; }
        else { error = data.code === 429 ? 'RATE_LIMITED' : 'UPSTREAM_REJECTED'; retry = data.code === 429 || data.code >= 500; }
      }
    } catch { /* Network/invalid JSON/credential decryption failures remain redacted. */ }
    const delay = Math.max(retryAfter, 1000 * 2 ** (job.attempts - 1) * (1 + deps.random() * 0.25));
    const next = now + delay;
    const again = result !== 'accepted' && retry && job.attempts < 6 && next < job.created_at + DAY;
    await atomic(db, [
      q(db, `UPDATE v2_outbox SET state=?,error=?,next_at=?,lease_until=0 WHERE notification_id=? AND lease_token=?`,
        again ? 'queued' : result, error, next, job.notification_id, lease),
      q(db, `UPDATE v2_bark SET last_attempt=?,last_result=?,last_error=? WHERE device_id=? AND version=?
        AND EXISTS(SELECT 1 FROM v2_outbox WHERE notification_id=? AND lease_token=?)`,
        now, again ? 'queued' : result, error, job.device_id, job.binding_version, job.notification_id, lease)
    ]);
  }
}

export async function cleanup(db, now) {
  await db.batch([
    q(db, `UPDATE v2_devices SET floor_seq=MAX(floor_seq,COALESCE((SELECT MAX(seq) FROM v2_events e
      WHERE e.device_id=v2_devices.device_id AND e.expires_at<=?),0))`, now),
    q(db, 'DELETE FROM v2_events WHERE seq IN (SELECT seq FROM v2_events WHERE expires_at<=? LIMIT 1000)', now),
    q(db, 'DELETE FROM v2_sessions WHERE expires_at<=?', now),
    q(db, 'DELETE FROM v2_rate_limits WHERE window<?', Math.floor(now / 60000) - 1440),
    q(db,'DELETE FROM messages WHERE seq IN(SELECT seq FROM messages WHERE created_at<=? LIMIT 1000)',now-30*DAY),
    q(db,'DELETE FROM v2_notification_summaries WHERE window_end<?',now-7*DAY),
    q(db, `DELETE FROM v2_outbox WHERE notification_id IN (SELECT notification_id FROM v2_outbox
      WHERE state NOT IN ('queued','leased') AND created_at<? LIMIT 1000)`, now - 7 * DAY),
    q(db, `DELETE FROM v2_deliveries WHERE message_id IN (SELECT message_id FROM v2_messages WHERE expires_at<=?)`, now),
    q(db, `DELETE FROM v2_keys WHERE revision<(SELECT key_revision FROM v2_devices WHERE device_id=v2_keys.device_id)
      AND NOT EXISTS(SELECT 1 FROM v2_events WHERE expires_at>? AND type='message' AND
      (json_extract(payload,'$.envelope.sender_key_id')=v2_keys.key_id OR
      json_extract(payload,'$.envelope.recipient_key_id')=v2_keys.key_id OR
      json_extract(payload,'$.envelope.own_key_id')=v2_keys.key_id))`, now)
  ]);
}
