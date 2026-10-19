import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, keyPair } from './helpers.js';
import { base64, DAY } from '../src/common.js';
import { decrypt, encrypt, aad } from '../src/protocol.js';
import { drainBark, cleanup, barkOrigin } from '../src/bark.js';

test('capabilities are truthful, HTTPS/method/query/body guards, missing config fails closed', async () => {
  const f = await fixture();
  assert.equal((await f.call('/chat/v2/capabilities')).status, 200);
  assert.equal((await f.call('/chat/v2/capabilities?token=secret')).status, 400);
  assert.equal((await f.call('/chat/v2/capabilities?x=1')).status, 400);
  assert.equal((await f.call('/chat/v2/capabilities', null, 'POST', {})).status, 405);
  assert.equal((await f.worker.fetch(new Request('http://chat.example/chat/ping'), f.env)).status, 400);
  delete f.env.CURSOR_SECRET;
  assert.equal((await f.call('/chat/v2/capabilities')).status, 503);
  assert.equal((await f.call('/chat/ping')).data.mode, 'd1');
});

test('authentication requires stable identity, no nickname fallback, business errors and outages distinguished', async () => {
  const f = await fixture();
  for (const data of [{ nickname: 'alice', id: 1 }, { username: 'alice' }, { username: 'alice', id: 1, banned: true }]) {
    f.setAuth(() => Response.json({ code: 200, data }));
    const r = await f.call('/chat/v2/session', 'main', 'POST', { device_id: crypto.randomUUID(), device_name: 'test' });
    assert.ok([403, 409].includes(r.status));
  }
  f.setAuth(() => Response.json({ code: 401 }));
  assert.equal((await f.call('/chat/v2/session', 'main', 'POST', { device_id: crypto.randomUUID(), device_name: 'test' })).status, 401);
  f.setAuth(() => { throw new Error('contains secret'); });
  const r = await f.call('/chat/v2/session', 'main', 'POST', { device_id: crypto.randomUUID(), device_name: 'test' });
  assert.equal(r.status, 503); assert.ok(!JSON.stringify(r.data).includes('secret'));
});

test('device ownership, short session expiration, revocation, limit and identity conflicts', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  assert.equal((await f.call(`/chat/v2/devices/${a.device_id}`, b.token, 'DELETE')).status, 403);
  const r = await f.call(`/chat/v2/devices/${a.device_id}`, a.token, 'DELETE'); assert.equal(r.status, 200);
  assert.equal((await f.call('/chat/v2/devices', a.token)).status, 401);
  assert.equal((await f.call('/chat/v2/session', a.mainToken, 'POST', { device_id: a.device_id, device_name: 'old' })).status, 403);
  f.tick(3600001); assert.equal((await f.call('/chat/v2/devices', b.token)).status, 401);
  assert.ok(f.db.primaryReads > 0);
});

test('public key validation, CAS, concurrent identical replays and per-device dual algorithms', async () => {
  const f = await fixture(); const a = await f.user('alice', 1, false);
  const keys = await Promise.all(['X25519', 'P256'].map(keyPair));
  const request = { expected_revision: '0', keys: keys.map(({ privateKey, ...k }) => k) };
  const results = await Promise.all(Array.from({ length: 3 }, () => f.call(`/chat/v2/devices/${a.device_id}/keys`, a.token, 'POST', request)));
  assert.ok(results.every(r => r.status === 200));
  assert.equal(f.db.raw.prepare('SELECT keyset_revision FROM v2_accounts').get().keyset_revision, 1);
  assert.equal((await f.call(`/chat/v2/devices/${a.device_id}/keys`, a.token, 'POST', { ...request, keys: [{ ...request.keys[0], public_key: 'AAAA' }, request.keys[1]] })).status, 400);
  const changed = await Promise.all(['X25519', 'P256'].map(keyPair));
  assert.equal((await f.call(`/chat/v2/devices/${a.device_id}/keys`, a.token, 'POST', {
    ...request, keys: changed.map(({ privateKey, ...k }) => k)
  })).status, 409);
});

test('send/sync/ack/read work, sender copy is not recipient delivery, read requires reception', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2); const c = await f.user('charlie', 3);
  const request = await f.message(a, b); const sent = await f.call('/chat/v2/messages', a.token, 'POST', request);
  assert.equal(sent.status, 200, JSON.stringify(sent.data));
  const { conversation_id, conversation_seq } = sent.data.data;
  assert.equal((await f.call(`/chat/v2/conversations/${conversation_id}/read`, b.token, 'POST', { up_to_conversation_seq: conversation_seq })).status, 400);
  assert.equal((await f.call(`/chat/v2/conversations/${conversation_id}/read`, c.token, 'POST', { up_to_conversation_seq: conversation_seq })).status, 403);
  const own = await f.call('/chat/v2/sync', a.token); assert.equal(own.status, 200);
  await f.call('/chat/v2/sync/ack', a.token, 'POST', { cursor: own.data.data.next_cursor });
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_deliveries').get().n, 0);
  const incoming = await f.call('/chat/v2/sync', b.token);
  const msg = incoming.data.data.events.find(e => e.type === 'message'); assert.ok(msg);
  const meta = { ...msg, ...msg.envelope };
  assert.equal(await decrypt(b.keys[0].privateKey, a.keys[0].public_key, meta, msg.envelope), '你好，世界🌊');
  const cursor = incoming.data.data.next_cursor;
  assert.equal((await f.call('/chat/v2/sync/ack', b.token, 'POST', { cursor })).status, 200);
  assert.equal((await f.call('/chat/v2/sync/ack', b.token, 'POST', { cursor })).status, 200);
  const read = await f.call(`/chat/v2/conversations/${conversation_id}/read`, b.token, 'POST', { up_to_conversation_seq: conversation_seq });
  assert.equal(read.status, 200, JSON.stringify(read.data));
  assert.equal((await f.call(`/chat/v2/conversations/${conversation_id}/read`, b.token, 'POST', { up_to_conversation_seq: conversation_seq })).status, 200);
  const events = (await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(own.data.data.next_cursor)}`, a.token)).data.data.events;
  assert.equal(events.filter(e => e.type === 'read').length, 1);
  assert.equal(events.filter(e => e.type === 'delivered').length, 1);
});

test('atomic send deduplicates 20 concurrent identical retries and rejects changed content', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  const request = await f.message(a, b);
  const results = await Promise.all(Array.from({ length: 20 }, () => f.call('/chat/v2/messages', a.token, 'POST', request)));
  assert.ok(results.every(r => r.status === 200), JSON.stringify(results.find(r => r.status !== 200)));
  assert.equal(new Set(results.map(r => r.data.data.message_id)).size, 1);
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_messages').get().n, 1);
  assert.equal(f.db.raw.prepare("SELECT COUNT(*) AS n FROM v2_events WHERE type='message'").get().n, 2);
  const bad = await f.call('/chat/v2/messages', a.token, 'POST', { ...request, client_sent_at_ms: request.client_sent_at_ms + 1 });
  assert.equal(bad.status, 409); assert.equal(bad.data.error.code, 'IDEMPOTENCY_CONFLICT');
});

test('accepted retry survives key rotation, stale new request rejected, partial SQL failure rolls back', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  const old = await f.message(a, b); const next = await f.message(a, b);
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', old)).status, 200);
  const keys = await Promise.all(['X25519', 'P256'].map(keyPair));
  assert.equal((await f.call(`/chat/v2/devices/${b.device_id}/keys`, b.token, 'POST', {
    expected_revision: '1', keys: keys.map(({ privateKey, ...k }) => k)
  })).status, 200);
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', old)).status, 200);
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', next)).status, 409);
  b.keys = keys; const request = await f.message(a, b);
  f.db.raw.exec("CREATE TRIGGER fail_event BEFORE INSERT ON v2_events WHEN NEW.type='message' BEGIN SELECT RAISE(ABORT,'injected failure'); END");
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', request)).status, 503);
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_messages').get().n, 1);
  f.db.raw.exec('DROP TRIGGER fail_event');
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', request)).status, 200);
});

test('true pagination beyond 200, same timestamps, all conversations, tamper/owner cursor rejection', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  // Seed 501 real persisted events without bypassing the sync/ack SQL path.
  const stmt = f.db.raw.prepare("INSERT INTO v2_events(device_id,dedup,type,payload,expires_at) VALUES(?,?,'test',?,?)");
  for (let i = 0; i < 501; i++) stmt.run(b.device_id, `test:${i}`, JSON.stringify({ type: 'test', i }), f.now() + DAY);
  let cursor; const all = [];
  do {
    const r = await f.call('/chat/v2/sync?limit=100' + (cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''), b.token);
    assert.equal(r.status, 200); all.push(...r.data.data.events); cursor = r.data.data.next_cursor;
    if (!r.data.data.has_more) break;
  } while (true);
  assert.equal(all.filter(e => e.type === 'test').length, 501);
  assert.equal(new Set(all.map(e => e.event_seq)).size, all.length);
  assert.equal((await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(cursor)}`, a.token)).status, 403);
  assert.equal((await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(cursor.slice(1))}`, b.token)).status, 400);
  const empty = await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(cursor)}`, b.token);
  assert.equal(empty.data.data.events.length, 0); assert.ok(empty.data.data.next_cursor);
});

test('expiry reports gap and reset retains local/ack semantics without reviving expired content', async () => {
  const f = await fixture(); const a = await f.user('alice', 1);
  const old = (await f.call('/chat/v2/sync', a.token)).data.data.next_cursor;
  f.tick(31 * DAY); await cleanup(f.db, f.now());
  // Reauthenticate same identity/device after its one-hour token expired.
  const session = await f.call('/chat/v2/session', a.mainToken, 'POST', { device_id: a.device_id, device_name: 'same' }); a.token = session.data.data.chat_token;
  // Seed an expired event after old cursor to model offline missed history.
  f.db.raw.prepare("INSERT INTO v2_events(device_id,dedup,type,payload,expires_at) VALUES(?,'expired','test','{}',?)").run(a.device_id, f.now() - 1);
  const r = await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(old)}`, a.token); assert.equal(r.status, 410);
  const reset = await f.call('/chat/v2/sync/reset', a.token, 'POST', { reason: 'cursor_expired' });
  assert.equal(reset.status, 200); assert.equal(reset.data.data.history_complete, false);
  assert.equal((await f.call(`/chat/v2/sync?cursor=${encodeURIComponent(reset.data.data.cursor)}`, a.token)).status, 200);
});

test('multiple devices get distinct envelopes, new device has no historical message', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2); const b2 = await f.user('bob', 2);
  const request = await f.message(a, b, 'P256消息', 'P256');
  assert.equal(request.envelopes.length, 3);
  const incomplete = { ...request, envelopes: request.envelopes.slice(1) };
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', incomplete)).status, 400);
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', request)).status, 200);
  for (const receiver of [b, b2]) {
    const e = (await f.call('/chat/v2/sync', receiver.token)).data.data.events.find(e => e.type === 'message');
    assert.equal(await decrypt(receiver.keys[1].privateKey, a.keys[1].public_key, { ...e, ...e.envelope }, e.envelope), 'P256消息');
  }
  const b3 = await f.user('bob', 2);
  assert.equal((await f.call('/chat/v2/sync', b3.token)).data.data.events.filter(e => e.type === 'message').length, 0);
});

test('AES-GCM authenticates AAD, ciphertext and both algorithm suites', async () => {
  for (const algorithm of ['X25519', 'P256']) {
    const a = await keyPair(algorithm); const b = await keyPair(algorithm);
    const meta = { sender_subject: 'a', sender_device_id: 'a1', recipient_subject: 'b', client_msg_id: 'msg',
      target_subject: 'b', target_device_id: 'b1', algorithm, sender_key_id: a.key_id, recipient_key_id: b.key_id };
    const e = await encrypt(a.privateKey, b.public_key, meta, '中文 🌊');
    assert.equal(await decrypt(b.privateKey, a.public_key, meta, e), '中文 🌊');
    await assert.rejects(decrypt(b.privateKey, a.public_key, { ...meta, client_msg_id: 'tampered' }, e));
    const tampered = { ...e, ciphertext: base64(new Uint8Array(32)) };
    await assert.rejects(decrypt(b.privateKey, a.public_key, meta, tampered));
  }
});

test('Bark binding encrypts secret, outbox dedups, generic notifications never carry chat/auth data', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  const binding = await f.call(`/chat/v2/devices/${b.device_id}/bark`, b.token, 'PUT', { server_url: 'https://api.day.app', device_key: 'bark-secret', enabled: true });
  assert.equal(binding.status, 200); assert.ok(!JSON.stringify(binding).includes('bark-secret'));
  assert.ok(!f.db.raw.prepare('SELECT encrypted_key FROM v2_bark').get().encrypted_key.includes('bark-secret'));
  const request = await f.message(a, b, 'private content');
  assert.equal((await f.call('/chat/v2/messages', a.token, 'POST', request)).status, 200);
  await f.call('/chat/v2/messages', a.token, 'POST', request);
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_outbox').get().n, 1);
  await Promise.all([drainBark(f.env, f.db, f.deps), drainBark(f.env, f.db, f.deps)]);
  assert.equal(f.bark.length, 1); assert.equal(f.bark[0].body, '收到新私聊，请打开应用查看');
  assert.ok(!JSON.stringify(f.bark).includes('private content')); assert.ok(!JSON.stringify(f.bark).includes(a.mainToken));
  assert.equal((await f.call(`/chat/v2/devices/${b.device_id}/bark/status`, b.token)).data.data.last_result, 'accepted');
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_deliveries').get().n, 0);
});

test('Bark retry limit, Retry-After, cancellation, SSRF allowlist and no redirects', async () => {
  const f = await fixture(); const b = await f.user('bob', 2);
  for (const url of ['http://api.day.app', 'https://localhost', 'https://127.0.0.1', 'https://169.254.169.254', 'https://evil.example', 'https://api.day.app/path', 'https://api.day.app/?x=1', 'https://user@api.day.app']) {
    assert.throws(() => barkOrigin(url, f.env));
  }
  await f.call(`/chat/v2/devices/${b.device_id}/bark`, b.token, 'PUT', { server_url: 'https://api.day.app', device_key: 'secret', enabled: true });
  assert.equal((await f.call(`/chat/v2/devices/${b.device_id}/bark/test`, b.token, 'POST', {})).status, 200);
  f.setBark(() => Response.json({ code: 429 }, { status: 429, headers: { 'Retry-After': '60' } }));
  await drainBark(f.env, f.db, f.deps);
  const first = f.db.raw.prepare('SELECT * FROM v2_outbox').get(); assert.equal(first.next_at, f.now() + 60000);
  for (let i = 0; i < 6; i++) { f.tick(60000); await drainBark(f.env, f.db, f.deps); }
  assert.equal(f.bark.length, 6); assert.equal(f.db.raw.prepare('SELECT state FROM v2_outbox').get().state, 'failed');
  f.setBark(() => Response.json({ code: 200 }));
  await f.call(`/chat/v2/devices/${b.device_id}/bark/test`, b.token, 'POST', {});
  await f.call(`/chat/v2/devices/${b.device_id}/bark?expected_revision=1`, b.token, 'DELETE');
  await drainBark(f.env, f.db, f.deps); assert.equal(f.bark.length, 6);
  assert.equal((await f.call(`/chat/v2/devices/${b.device_id}/bark/status`, b.token)).data.data.enabled, false);
});

test('legacy adapter uses real schema, checks idempotency, cursor semantics, key confirmation and actual read range', async () => {
  const f = await fixture(); const a = await f.user('alice', 1); const b = await f.user('bob', 2);
  for (const u of [a, b]) assert.equal((await f.call('/chat/key', u.mainToken, 'POST', { userId: u.username, publicKey: u.keys[0].public_key })).status, 200);
  const request = { to: 'bob', from: 'alice', msgId: 'same-id', cipher: `${base64(new Uint8Array(12))}:${base64(new Uint8Array(16))}`, ts: f.now() };
  const sent = await f.call('/chat/send', a.mainToken, 'POST', request); assert.equal(sent.status, 200);
  assert.equal((await f.call('/chat/send', a.mainToken, 'POST', request)).data.duplicate, true);
  assert.equal((await f.call('/chat/send', a.mainToken, 'POST', { ...request, ts: request.ts + 1 })).status, 409);
  assert.equal((await f.call(`/chat/pull?since=${f.now()}`, b.mainToken)).status, 409);
  const page = await f.call('/chat/pull?cursor=0&limit=1', b.mainToken); assert.equal(page.data.data.length, 1);
  assert.equal((await f.call('/chat/read', a.mainToken, 'POST', { peerId: 'bob', upto: sent.data.seq })).status, 400);
  assert.equal((await f.call('/chat/read', b.mainToken, 'POST', { peerId: 'alice', upto: sent.data.seq })).status, 200);
  assert.equal((await f.call('/chat/read?peerId=bob', a.mainToken)).data.data.peer_upto, sent.data.seq);
  assert.equal((await f.call('/chat/key', a.mainToken, 'POST', { publicKey: a.keys[1].public_key })).status, 409);
  assert.equal((await f.call('/chat/key', a.mainToken, 'POST', { publicKey: a.keys[1].public_key, expectedPublicKey: a.keys[0].public_key })).status, 200);
});
