import { statement as q, rows, guard, fail, hash, bearer, DAY } from './common.js';
// Additive read-time metadata for native clients: stable subjects remain the
// authority; usernames are current display/addressing metadata. Public key is
// resolved by the envelope's immutable key_id, never by the current revision.
export const messagePayload=(e='e')=>`json_set(${e}.payload,
  '$.sender_username',(SELECT username FROM v2_accounts WHERE subject=json_extract(${e}.payload,'$.sender_subject')),
  '$.recipient_username',(SELECT username FROM v2_accounts WHERE subject=json_extract(${e}.payload,'$.recipient_subject')),
  '$.envelope.sender_public_key',COALESCE(json_extract(${e}.payload,'$.envelope.sender_public_key'),
    (SELECT public_key FROM v2_keys WHERE key_id=json_extract(${e}.payload,'$.envelope.sender_key_id'))))`;
export async function authenticate(req, db, now) {
  const tokenHash = await hash(bearer(req));
  const auth = await q(db, `SELECT d.*,a.username,CAST(d.key_revision AS TEXT) AS revision,
    CAST(d.ack_seq AS TEXT) AS ack,CAST(d.floor_seq AS TEXT) AS floor,
    CAST(d.max_issued_seq AS TEXT) AS issued,s.expires_at FROM v2_sessions s
    JOIN v2_devices d ON d.device_id=s.device_id JOIN v2_accounts a ON a.subject=d.subject
    WHERE s.token_hash=?`, tokenHash).first();
  if (!auth || auth.expires_at <= now) fail(401, 'SESSION_EXPIRED');
  if (auth.revoked) fail(403, 'DEVICE_REVOKED');
  return { ...auth, tokenHash };
}
export function sessionGuard(db, auth, now) {
  return guard(db, `EXISTS(SELECT 1 FROM v2_sessions s JOIN v2_devices d ON d.device_id=s.device_id
    WHERE s.token_hash=? AND s.expires_at>? AND d.revoked=0)`, auth.tokenHash, now);
}
export function active(auth) { if (!auth.active) fail(403, 'DEVICE_NOT_ACTIVE'); }
export async function bundle(db, owner) {
  const a = await q(db, 'SELECT subject,username,CAST(keyset_revision AS TEXT) AS keyset_revision FROM v2_accounts WHERE subject=?', owner).first();
  if (!a) fail(404, 'USER_NOT_FOUND');
  const devices = await rows(q(db, `SELECT device_id,CAST(key_revision AS TEXT) AS key_revision FROM v2_devices
    WHERE subject=? AND active=1 AND revoked=0 ORDER BY device_id`, owner));
  const keys = await rows(q(db, `SELECT k.device_id,k.key_id,k.algorithm,k.public_key FROM v2_keys k
    JOIN v2_devices d ON d.device_id=k.device_id AND d.key_revision=k.revision
    WHERE d.subject=? AND d.active=1 AND d.revoked=0 ORDER BY k.algorithm`, owner));
  for (const d of devices) d.keys = keys.filter(k => k.device_id === d.device_id).map(({ device_id, ...k }) => k);
  return { ...a, devices };
}
// Literal JSON is bound, never interpolated. Dedup identity is independent of seq.
export function event(db, device, dedup, type, payload, now, messageId = null) {
  return q(db, `INSERT INTO v2_events(device_id,dedup,type,message_id,payload,expires_at)
    VALUES(?,?,?,?,?,?) ON CONFLICT(device_id,dedup) DO NOTHING`, device, dedup, type, messageId, JSON.stringify(payload), now + 30 * DAY);
}
export function keysetEvents(db, owner, now) {
  return q(db, `INSERT INTO v2_events(device_id,dedup,type,payload,expires_at)
    SELECT d.device_id,'key:'||a.subject||':'||a.keyset_revision,'keyset_changed',
    json_object('type','keyset_changed','subject',a.subject,'keyset_revision',CAST(a.keyset_revision AS TEXT),'changed_at_ms',?),?
    FROM v2_devices d JOIN v2_accounts a ON a.subject=?
    WHERE d.active=1 AND d.revoked=0 AND (d.subject=a.subject OR EXISTS(
      SELECT 1 FROM v2_messages m WHERE m.expires_at>? AND
      ((m.sender=a.subject AND m.recipient=d.subject) OR (m.recipient=a.subject AND m.sender=d.subject))))
    ON CONFLICT(device_id,dedup) DO NOTHING`, now, now + 30 * DAY, owner, now);
}
export async function currentFloor(db, device, now) {
  const r = await q(db, `SELECT CAST(MAX(floor_seq,COALESCE((SELECT MAX(seq) FROM v2_events
    WHERE device_id=? AND expires_at<=?),0)) AS TEXT) AS floor FROM v2_devices WHERE device_id=?`, device, now, device).first();
  return r.floor;
}
export async function conversation(db, id, owner) {
  const c = await q(db, 'SELECT * FROM v2_conversations WHERE conversation_id=?', id).first();
  if (!c) fail(404, 'MESSAGE_NOT_FOUND');
  if (c.a !== owner && c.b !== owner) fail(403, 'FORBIDDEN');
  return c;
}
export async function accepted(db, auth, id) {
  return q(db, `SELECT message_id,client_msg_id,conversation_id,CAST(seq AS TEXT) AS conversation_seq,
    accepted_at AS accepted_at_ms,request_hash FROM v2_messages WHERE sender=? AND sender_device=? AND client_msg_id=?`,
  auth.subject, auth.device_id, id).first();
}
export function acceptance(row, duplicate) {
  const { request_hash: ignored, ...result } = row;
  return { ...result, duplicate };
}
