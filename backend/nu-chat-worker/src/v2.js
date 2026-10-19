import { fail, object, body, noBody, text, username, uuid, sequence, query, mainIdentity,
  subject, base64, hash, publicKey, canonical, secret, unbase64, statement as q,
  rows, guard, atomic, rate, DAY } from './common.js';
import { authenticate, sessionGuard, active, bundle, keysetEvents, currentFloor,
  conversation, accepted, acceptance, messagePayload } from './store.js';
import { parseCursor, signCursor } from './cursor.js';
import { barkRoute, barkEnabled } from './bark.js';
import { socialRoute, deliveryGuard, visible } from './social.js';
import { notificationRoute } from './notifications.js';
import { recoveryRoute,recoveryLimits } from './recovery.js';
import { androidRoute } from './android.js';

export async function v2(req, env, db, url, deps) {
  const now = deps.now(); const path = url.pathname; const method = req.method;
  secret(env, 'CURSOR_SECRET');
  const ok = data => data === undefined ? { ok: true } : { ok: true, data };
  if (path === '/chat/v2/capabilities' && method === 'GET') {
    query(url, []); await noBody(req);
    // Check schema as well as configuration before claiming this implementation.
    if (!await q(db, 'SELECT id FROM v2_guard WHERE id=1 AND valid=1').first()) fail(503, 'NOT_CONFIGURED');
    if (!await q(db,'SELECT version FROM v2_schema WHERE version=4').first())fail(503,'NOT_CONFIGURED');
    if(env.HISTORY_BUCKET?.put)recoveryLimits(env);
    return ok({ protocol: 'nu-chat-v2', version: 2, algorithms: ['X25519', 'P256'],
      features: ['cursor_sync', 'idempotent_send', 'device_keys', 'receipts','conversations','blocks','private_reads','history_controls','notification_preferences','legacy_android_interop',
        ...(env.HISTORY_BUCKET?.put?['encrypted_backups','device_history_transfer']:[]),...(barkEnabled(env) ? ['bark'] : [])],
      retention_days: 30, max_page_size: 200, max_devices_per_account: 8,
      max_plaintext_bytes: 16384, max_request_bytes: 524288, max_envelopes: 16 });
  }
  if (path === '/chat/v2/session' && method === 'POST') {
    query(url, []);
    await rate(db, `session:${req.headers.get('CF-Connecting-IP') || 'unknown'}`, 10, now);
    const b = object(await body(req), ['device_id', 'device_name']);
    const deviceId = uuid(b.device_id); text(b.device_name, 64);
    const identity = await mainIdentity(req, deps.fetch); const owner = subject(identity);
    const d = await q(db, 'SELECT * FROM v2_devices WHERE device_id=?', deviceId).first();
    if (d && d.subject !== owner) fail(403, 'FORBIDDEN');
    if (d?.revoked) fail(403, 'DEVICE_REVOKED');
    const token = base64(crypto.getRandomValues(new Uint8Array(32)));
    const tokenHash = await hash(token);
    if (!d && (await q(db, 'SELECT COUNT(*) AS n FROM v2_devices WHERE subject=? AND revoked=0', owner).first()).n >= 8) fail(409, 'DEVICE_LIMIT');
    await atomic(db, [
      guard(db, `NOT EXISTS(SELECT 1 FROM v2_devices WHERE device_id=? AND (subject<>? OR revoked=1))
        AND (EXISTS(SELECT 1 FROM v2_devices WHERE device_id=?) OR
        (SELECT COUNT(*) FROM v2_devices WHERE subject=? AND revoked=0)<8)`, deviceId, owner, deviceId, owner),
      q(db, `INSERT INTO v2_accounts(subject,username) VALUES(?,?)
        ON CONFLICT(subject) DO UPDATE SET username=excluded.username`, owner, identity.username),
      q(db, `INSERT INTO v2_devices(device_id,subject,name,created_at) VALUES(?,?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET name=excluded.name`, deviceId, owner, b.device_name, now),
      q(db, 'INSERT INTO v2_sessions(token_hash,device_id,expires_at) VALUES(?,?,?)', tokenHash, deviceId, now + 3600000)
    ], 'DEVICE_LIMIT_OR_IDENTITY_CONFLICT');
    return ok({ subject: owner, username: identity.username, device_id: deviceId, chat_token: token, expires_at_ms: now + 3600000 });
  }
  const auth = await authenticate(req, db, now);
  const sg = () => sessionGuard(db, auth, now);
  const android = await androidRoute(req, env, db, url, auth, deps);
  if (android) return android;
  const social = await socialRoute(req, env, db, url, auth, deps);
  if (social) return social;
  const notifications=await notificationRoute(req,env,db,url,auth,deps);
  if(notifications) return notifications;
  const recovery=await recoveryRoute(req,env,db,url,auth,deps);
  if(recovery)return recovery;
  if (path === '/chat/v2/session' && method === 'DELETE') {
    query(url, []); await noBody(req);
    await q(db, 'DELETE FROM v2_sessions WHERE token_hash=?', auth.tokenHash).run(); return ok();
  }
  if (path === '/chat/v2/devices' && method === 'GET') {
    query(url, []); await noBody(req);
    const devices = await rows(q(db, `SELECT device_id,name AS device_name,active,revoked,
      CAST(key_revision AS TEXT) AS key_revision,created_at AS created_at_ms FROM v2_devices WHERE subject=? ORDER BY created_at,device_id`, auth.subject));
    return ok({ devices: devices.map(d => ({ ...d, active: !!d.active, revoked: !!d.revoked })) });
  }
  let m = path.match(/^\/chat\/v2\/devices\/([^/]+)\/keys$/);
  if (m && method === 'POST') {
    query(url, []);
    const id = uuid(m[1]); if (id !== auth.device_id) fail(403, 'FORBIDDEN');
    const b = object(await body(req), ['expected_revision', 'keys']); sequence(b.expected_revision);
    if (!Array.isArray(b.keys) || b.keys.length !== 2) fail(400, 'INVALID_REQUEST');
    const algorithms = new Set(); const ids = new Set();
    for (const k of b.keys) {
      object(k, ['key_id', 'algorithm', 'public_key']); uuid(k.key_id);
      if (algorithms.has(k.algorithm) || ids.has(k.key_id)) fail(400, 'INVALID_REQUEST');
      await publicKey(k.algorithm, k.public_key); algorithms.add(k.algorithm); ids.add(k.key_id);
    }
    const requestHash = await hash(canonical(b));
    const replay = await q(db, 'SELECT request_hash,result FROM v2_key_operations WHERE device_id=? AND expected_revision=?', id, b.expected_revision).first();
    if (replay) {
      if (replay.request_hash !== requestHash) fail(409, 'REVISION_CONFLICT');
      return ok(JSON.parse(replay.result));
    }
    if (b.expected_revision !== auth.revision) fail(409, 'REVISION_CONFLICT');
    const statements = [sg(), guard(db, 'EXISTS(SELECT 1 FROM v2_devices WHERE device_id=? AND key_revision=? AND revoked=0)', id, b.expected_revision),
      q(db, 'UPDATE v2_devices SET key_revision=key_revision+1,active=1 WHERE device_id=?', id),
      q(db, 'UPDATE v2_accounts SET keyset_revision=keyset_revision+1 WHERE subject=?', auth.subject)];
    for (const k of b.keys) statements.push(q(db, `INSERT INTO v2_keys(key_id,device_id,algorithm,public_key,revision)
      SELECT ?,?,?,?,key_revision FROM v2_devices WHERE device_id=?`, k.key_id, id, k.algorithm, k.public_key, id));
    statements.push(q(db, `INSERT INTO v2_key_operations(device_id,expected_revision,request_hash,result)
      SELECT ?,?,?,json_object('device_id',d.device_id,'key_revision',CAST(d.key_revision AS TEXT),
      'keyset_revision',CAST(a.keyset_revision AS TEXT),'active',json('true')) FROM v2_devices d
      JOIN v2_accounts a ON a.subject=d.subject WHERE d.device_id=?`, id, b.expected_revision, requestHash, id),
    keysetEvents(db, auth.subject, now));
    try { await atomic(db, statements); }
    catch (e) {
      // Concurrent identical registration is a replay, not a second key rotation.
      const r = await q(db, 'SELECT request_hash,result FROM v2_key_operations WHERE device_id=? AND expected_revision=?', id, b.expected_revision).first();
      if (r?.request_hash === requestHash) return ok(JSON.parse(r.result));
      throw e;
    }
    const result = await q(db, 'SELECT result FROM v2_key_operations WHERE device_id=? AND expected_revision=?', id, b.expected_revision).first();
    return ok(JSON.parse(result.result));
  }
  m = path.match(/^\/chat\/v2\/devices\/([^/]+)$/);
  if (m && method === 'DELETE') {
    query(url, []); await noBody(req); const id = uuid(m[1]);
    const target = await q(db, 'SELECT subject,revoked FROM v2_devices WHERE device_id=?', id).first();
    if (!target) fail(404, 'DEVICE_NOT_FOUND');
    if (target.subject !== auth.subject) fail(403, 'FORBIDDEN');
    if (target.revoked) return ok();
    await atomic(db, [sg(),
      // Increment only once, even when two sessions revoke the same device.
      q(db, `UPDATE v2_accounts SET keyset_revision=keyset_revision+1 WHERE subject=?
        AND EXISTS(SELECT 1 FROM v2_devices WHERE device_id=? AND revoked=0)`, auth.subject, id),
      q(db, 'UPDATE v2_devices SET revoked=1,active=0 WHERE device_id=?', id),
      q(db, 'DELETE FROM v2_sessions WHERE device_id=?', id),
      q(db, 'DELETE FROM v2_bark WHERE device_id=?', id),
      q(db, "UPDATE v2_outbox SET state='cancelled',lease_token=NULL,lease_until=0 WHERE device_id=? AND state IN ('queued','leased')", id),
      q(db,`UPDATE v2_recovery_packs SET state='deleting',revision=revision+1 WHERE kind='transfer' AND
        (source_device=? OR target_device=?) AND state IN('awaiting_approval','uploading','ready')`,id,id),
      keysetEvents(db, auth.subject, now)]);
    return ok();
  }
  m = path.match(/^\/chat\/v2\/users\/([^/]+)\/keys$/);
  if (m && method === 'GET') {
    query(url, []); await noBody(req); let name;
    try { name = decodeURIComponent(m[1]); } catch { fail(400, 'INVALID_REQUEST'); }
    username(name);
    const a = await q(db, 'SELECT subject FROM v2_accounts WHERE username=?', name).first();
    if (!a) fail(404, 'USER_NOT_FOUND');
    return ok(await bundle(db, a.subject));
  }
  if (path === '/chat/v2/messages' && method === 'POST') {
    query(url, []); active(auth);
    const b = object(await body(req), ['client_msg_id', 'to_subject', 'client_sent_at_ms',
      'sender_keyset_revision', 'recipient_keyset_revision', 'envelopes']);
    uuid(b.client_msg_id); text(b.to_subject); sequence(b.sender_keyset_revision); sequence(b.recipient_keyset_revision);
    if (!Number.isSafeInteger(b.client_sent_at_ms) || b.client_sent_at_ms < 0 || b.to_subject === auth.subject) fail(400, 'INVALID_REQUEST');
    const requestHash = await hash(canonical(b));
    const prior = await accepted(db, auth, b.client_msg_id);
    if (prior) {
      if (prior.request_hash !== requestHash) fail(409, 'IDEMPOTENCY_CONFLICT');
      return ok(acceptance(prior, true));
    }
    await rate(db, `send:${auth.subject}`, 30, now);
    try { await atomic(db, [deliveryGuard(db, auth.subject, b.to_subject)], 'DELIVERY_NOT_ALLOWED'); }
    catch { fail(409, 'DELIVERY_NOT_ALLOWED'); }
    const sender = await bundle(db, auth.subject); const recipient = await bundle(db, b.to_subject);
    if (!recipient.devices.length) fail(409, 'NO_ACTIVE_DEVICE');
    if (sender.keyset_revision !== b.sender_keyset_revision || recipient.keyset_revision !== b.recipient_keyset_revision) fail(409, 'KEYSET_CHANGED');
    const targets = new Map();
    for (const account of [sender, recipient]) for (const device of account.devices) targets.set(device.device_id, { account, device });
    if (!Array.isArray(b.envelopes) || b.envelopes.length !== targets.size || targets.size > 16) fail(400, 'INVALID_REQUEST');
    const seen = new Set();
    const local = sender.devices.find(d => d.device_id === auth.device_id);
    for (const e of b.envelopes) {
      object(e, ['target_subject', 'target_device_id', 'algorithm', 'sender_key_id', 'recipient_key_id', 'nonce', 'ciphertext']);
      uuid(e.target_device_id); uuid(e.sender_key_id); uuid(e.recipient_key_id);
      const target = targets.get(e.target_device_id);
      if (!target || seen.has(e.target_device_id) || target.account.subject !== e.target_subject) fail(400, 'INVALID_REQUEST');
      seen.add(e.target_device_id);
      const recipientKey = target.device.keys.find(k => k.key_id === e.recipient_key_id && k.algorithm === e.algorithm);
      if (!recipientKey || !local?.keys.some(k => k.key_id === e.sender_key_id && k.algorithm === e.algorithm)) fail(409, 'KEYSET_CHANGED');
      if (unbase64(e.nonce, 12).length !== 12 || unbase64(e.ciphertext, 16400).length < 16) fail(400, 'INVALID_REQUEST');
    }
    const [a, z] = [auth.subject, b.to_subject].sort(); const messageId = crypto.randomUUID();
    const sameRequest = `EXISTS(SELECT 1 FROM v2_messages WHERE sender=? AND sender_device=? AND client_msg_id=? AND request_hash=?)`;
    const sameArgs = [auth.subject, auth.device_id, b.client_msg_id, requestHash];
    const stmts = [sg(), deliveryGuard(db, auth.subject, b.to_subject), guard(db, `${sameRequest} OR (
      EXISTS(SELECT 1 FROM v2_accounts WHERE subject=? AND keyset_revision=?) AND
      EXISTS(SELECT 1 FROM v2_accounts WHERE subject=? AND keyset_revision=?))`,
    ...sameArgs, auth.subject, b.sender_keyset_revision, b.to_subject, b.recipient_keyset_revision),
    guard(db, `NOT EXISTS(SELECT 1 FROM v2_messages WHERE sender=? AND sender_device=? AND client_msg_id=? AND request_hash<>?)`, ...sameArgs),
    q(db, `INSERT INTO v2_conversations(conversation_id,a,b) VALUES(?,?,?) ON CONFLICT(a,b) DO NOTHING`, crypto.randomUUID(), a, z),
    q(db, `INSERT INTO v2_messages(message_id,client_msg_id,sender,sender_device,recipient,conversation_id,request_hash,accepted_at,expires_at)
      SELECT ?,?,?,?,?,conversation_id,?,?,? FROM v2_conversations WHERE a=? AND b=?
      ON CONFLICT(sender,sender_device,client_msg_id) DO NOTHING`,
    messageId, b.client_msg_id, auth.subject, auth.device_id, b.to_subject, requestHash, now, now + 30 * DAY, a, z)];
    for (const owner of [auth.subject,b.to_subject]) stmts.push(q(db, `INSERT INTO v2_copies(owner,message_id,expires_at)
      SELECT ?,m.message_id,MIN(m.expires_at,m.accepted_at+COALESCE((SELECT retention_days FROM v2_preferences WHERE subject=?),30)*?)
      FROM v2_messages m WHERE m.sender=? AND m.sender_device=? AND m.client_msg_id=? ON CONFLICT(owner,message_id) DO NOTHING`,
    owner,owner,DAY,auth.subject,auth.device_id,b.client_msg_id));
    for (const e of b.envelopes) {
      stmts.push(q(db, `INSERT INTO v2_events(device_id,dedup,type,message_id,payload,expires_at)
        SELECT ?,'msg:'||m.message_id,'message',m.message_id,
        json_object('type','message','message_id',m.message_id,'client_msg_id',m.client_msg_id,
        'conversation_id',m.conversation_id,'conversation_seq',CAST(m.seq AS TEXT),
        'sender_subject',m.sender,'sender_device_id',m.sender_device,'recipient_subject',m.recipient,
        'accepted_at_ms',m.accepted_at,'expires_at_ms',cp.expires_at,'envelope',json(?)),cp.expires_at
        FROM v2_messages m JOIN v2_copies cp ON cp.message_id=m.message_id AND cp.owner=? WHERE m.sender=? AND m.sender_device=? AND m.client_msg_id=?
        ON CONFLICT(device_id,dedup) DO NOTHING`, e.target_device_id, JSON.stringify(e), e.target_subject, auth.subject, auth.device_id, b.client_msg_id));
      if (barkEnabled(env) && e.target_subject === b.to_subject) stmts.push(q(db, `INSERT INTO v2_outbox
        (notification_id,device_id,message_id,binding_version,next_at,created_at)
        SELECT ?,?,m.message_id,k.version,?,? FROM v2_messages m JOIN v2_bark k ON k.device_id=? AND k.enabled=1
        WHERE m.sender=? AND m.sender_device=? AND m.client_msg_id=? ON CONFLICT(message_id,device_id) DO NOTHING`,
      crypto.randomUUID(), e.target_device_id, now, now, e.target_device_id, auth.subject, auth.device_id, b.client_msg_id));
    }
    try { await atomic(db, stmts, 'KEYSET_CHANGED'); }
    catch (e) {
      const replay = await accepted(db, auth, b.client_msg_id);
      if (replay?.request_hash === requestHash) return ok(acceptance(replay, true));
      if (replay) fail(409, 'IDEMPOTENCY_CONFLICT');
      throw e;
    }
    const row = await accepted(db, auth, b.client_msg_id);
    return ok(acceptance(row, row.message_id !== messageId));
  }
  if (path === '/chat/v2/sync' && method === 'GET') {
    query(url, ['cursor', 'limit']); await noBody(req); active(auth);
    const n = url.searchParams.get('limit') ?? '100';
    if (!/^[1-9][0-9]{0,2}$/.test(n) || Number(n) > 200) fail(400, 'INVALID_REQUEST');
    const limit = Number(n); const floor = await currentFloor(db, auth.device_id, now);
    const c = url.searchParams.has('cursor') ? await parseCursor(env, auth, url.searchParams.get('cursor')) : { p: '0', f: '0' };
    if (BigInt(c.p) < BigInt(floor) && BigInt(c.f) < BigInt(floor)) fail(410, 'CURSOR_EXPIRED');
    const list = await rows(q(db, `WITH v AS(SELECT ? AS owner,? AS now)
      SELECT CAST(e.seq AS TEXT) AS seq,CASE WHEN e.type='message' AND NOT(${visible()})
      THEN json_set(json_remove(e.payload,'$.envelope'),'$.unavailable',CASE WHEN m.recalled_at IS NOT NULL THEN 'recalled' ELSE 'hidden' END)
      WHEN e.type='message' THEN ${messagePayload()} ELSE e.payload END AS payload FROM v2_events e CROSS JOIN v LEFT JOIN v2_messages m ON m.message_id=e.message_id
      WHERE e.device_id=? AND e.seq>? AND e.expires_at>? ORDER BY e.seq LIMIT ?`, auth.subject,now,auth.device_id, c.p, now, limit + 1));
    const hasMore = list.length > limit; const page = list.slice(0, limit);
    const next = page.at(-1)?.seq ?? c.p;
    await atomic(db, [sg(), q(db, 'UPDATE v2_devices SET max_issued_seq=MAX(max_issued_seq,CAST(? AS INTEGER)) WHERE device_id=?', next, auth.device_id)]);
    return ok({ events: page.map(e => ({ event_seq: e.seq, ...JSON.parse(e.payload) })),
      next_cursor: await signCursor(env, auth, next, floor), has_more: hasMore, server_time_ms: now });
  }
  if (path === '/chat/v2/sync/reset' && method === 'POST') {
    query(url, []); active(auth);
    const b = object(await body(req), ['reason']); if (b.reason !== 'cursor_expired') fail(400, 'INVALID_REQUEST');
    const floor = await currentFloor(db, auth.device_id, now);
    const first = await q(db, `SELECT MIN(expires_at)-? AS available FROM v2_events WHERE device_id=? AND expires_at>?`, 30 * DAY, auth.device_id, now).first();
    return ok({ cursor: await signCursor(env, auth, '0', floor), available_from_ms: first.available ?? now, history_complete: false });
  }
  if (path === '/chat/v2/sync/ack' && method === 'POST') {
    query(url, []); active(auth);
    const b = object(await body(req), ['cursor']); const c = await parseCursor(env, auth, text(b.cursor, 2048));
    const floor = await currentFloor(db, auth.device_id, now);
    if (BigInt(c.p) < BigInt(floor) && BigInt(c.f) < BigInt(floor)) fail(410, 'CURSOR_EXPIRED');
    if (BigInt(c.p) > BigInt(auth.issued)) fail(400, 'INVALID_CURSOR');
    await atomic(db, [sg(),
      q(db, `INSERT INTO v2_deliveries(message_id,device_id,received_at)
        WITH v AS(SELECT ? AS owner,? AS now)
        SELECT m.message_id,?,? FROM v2_events e CROSS JOIN v JOIN v2_messages m ON m.message_id=e.message_id
        WHERE e.device_id=? AND e.type='message' AND e.seq<=? AND e.expires_at>?
        AND m.recipient=? AND ${visible()} ON CONFLICT(message_id,device_id) DO NOTHING`, auth.subject,now,auth.device_id, now, auth.device_id, c.p, now, auth.subject),
      q(db, 'UPDATE v2_devices SET ack_seq=MAX(ack_seq,CAST(? AS INTEGER)) WHERE device_id=?', c.p, auth.device_id),
      q(db, `INSERT INTO v2_events(device_id,dedup,type,message_id,payload,expires_at)
        SELECT d.device_id,'delivered:'||r.message_id||':'||r.device_id,'delivered',r.message_id,
        json_object('type','delivered','conversation_id',m.conversation_id,'message_id',m.message_id,
        'receiver_subject',m.recipient,'receiver_device_id',r.device_id,'received_at_ms',r.received_at),?
        FROM v2_deliveries r JOIN v2_messages m ON m.message_id=r.message_id
        JOIN v2_devices d ON d.subject IN (m.sender,m.recipient) AND d.active=1 AND d.revoked=0
        WHERE r.device_id=? AND m.expires_at>? ON CONFLICT(device_id,dedup) DO NOTHING`, now + 30 * DAY, auth.device_id, now)]);
    return ok();
  }
  m = path.match(/^\/chat\/v2\/conversations\/([^/]+)\/read$/);
  if (m && method === 'POST') {
    query(url, []); active(auth); const id = uuid(m[1]); await conversation(db, id, auth.subject);
    const b = object(await body(req), ['up_to_conversation_seq']); const upto = sequence(b.up_to_conversation_seq);
    const received = await q(db, `WITH v AS(SELECT ? AS owner,? AS now)
      SELECT CAST(e.seq AS TEXT) AS seq FROM v2_events e CROSS JOIN v JOIN v2_messages m ON m.message_id=e.message_id
      WHERE e.device_id=? AND e.type='message' AND m.conversation_id=? AND m.seq=?
      AND m.recipient=? AND e.seq<=? AND e.expires_at>? AND ${visible()}`, auth.subject,now,auth.device_id, id, upto, auth.subject, auth.ack, now).first();
    if (!received) fail(400, 'INVALID_READ_POSITION');
    await atomic(db, [sg(),
      q(db, `INSERT INTO v2_reads(conversation_id,reader,upto_seq,read_at,disclosed_seq)
        VALUES(?,?,?,?,CASE WHEN COALESCE((SELECT read_receipts FROM v2_preferences WHERE subject=?),1)=1 THEN ? ELSE 0 END)
        ON CONFLICT(conversation_id,reader) DO UPDATE SET upto_seq=MAX(v2_reads.upto_seq,excluded.upto_seq),
        disclosed_seq=MAX(v2_reads.disclosed_seq,excluded.disclosed_seq),
        read_at=CASE WHEN excluded.upto_seq>v2_reads.upto_seq THEN excluded.read_at ELSE v2_reads.read_at END`, id, auth.subject, upto, now,auth.subject,upto),
      q(db, `INSERT INTO v2_events(device_id,dedup,type,payload,expires_at)
        SELECT d.device_id,'read:'||r.conversation_id||':'||r.reader||':'||r.upto_seq,'read',
        json_object('type','read','conversation_id',r.conversation_id,'reader_subject',r.reader,
        'up_to_conversation_seq',CAST(r.upto_seq AS TEXT),'read_at_ms',r.read_at),?
        FROM v2_reads r JOIN v2_conversations c ON c.conversation_id=r.conversation_id
        JOIN v2_devices d ON d.subject IN(c.a,c.b) AND d.active=1 AND d.revoked=0
        WHERE r.conversation_id=? AND r.reader=? AND (d.subject=r.reader OR COALESCE((SELECT read_receipts FROM v2_preferences WHERE subject=r.reader),1)=1)
        ON CONFLICT(device_id,dedup) DO NOTHING`, now + 30 * DAY, id, auth.subject)]);
    return ok(await q(db, `SELECT reader AS reader_subject,CAST(upto_seq AS TEXT) AS up_to_conversation_seq,
      read_at AS read_at_ms FROM v2_reads WHERE conversation_id=? AND reader=?`, id, auth.subject).first());
  }
  if (/^\/chat\/v2\/devices\/[^/]+\/bark(?:\/test|\/status)?$/.test(path)) {
    return barkRoute(req, env, db, url, auth, deps);
  }
  fail(404, 'NOT_FOUND');
}
