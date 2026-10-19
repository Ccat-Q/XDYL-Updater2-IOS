import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import miniflare from 'miniflare';
import { build } from 'esbuild';
import { keyPair } from './helpers.js';
import { base64 } from '../src/common.js';
import {createHistoryCipher,newRecoveryKey} from '../src/recovery-crypto.js';
import {encryptLegacy,decryptLegacy} from '../src/protocol.js';

test('Cloudflare workerd + real D1/R2: all migrations, native/Android send, CAS, sync/read, preferences, filters and encrypted backup', async () => {
  const { Miniflare, convertV4MiniflareOptions } = miniflare;
  const built = await build({ entryPoints: [new URL('../src/index.js', import.meta.url).pathname],
    bundle: true, write: false, format: 'esm', target: 'es2022' });
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: built.outputFiles[0].text,
    compatibilityDate: '2026-10-01', d1Databases: ['DB'],r2Buckets:['HISTORY_BUCKET'],
    bindings: { CURSOR_SECRET: base64(new Uint8Array(32).fill(9)), BARK_ENABLED: 'false' },
    outboundService: async req => {
      assert.equal(req.url, 'https://login.lanternwaves.fun/user/profile');
      const token = req.headers.get('Authorization')?.slice(7);
      if (!['alice', 'bob'].includes(token)) return Response.json({ code: 401 }, { status: 401 });
      return Response.json({ code: 200, data: { id: token === 'alice' ? 1 : 2, username: token } });
    } }));
  try {
    const db = await mf.getD1Database('DB');
    for (const name of ['0001_legacy.sql', '0002_v2.sql', '0003_frontend.sql', '0004_android_interop.sql']) {
      const sql = readFileSync(new URL(`../migrations/${name}`, import.meta.url), 'utf8').replace(/--[^\n]*/g, '');
      await db.batch(sql.split(';').map(s => s.trim()).filter(Boolean).map(s => db.prepare(s)));
    }
    const call = async (path, token, method = 'GET', body,extra={}) => {
      const r = await mf.dispatchFetch(`https://chat.example${path}`, { method, headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body ? { 'Content-Type': body instanceof Uint8Array?'application/octet-stream':'application/json' } : {}), 'CF-Connecting-IP': '203.0.113.9',...extra
      }, body: body ? body instanceof Uint8Array?body:JSON.stringify(body) : undefined });
      return { status: r.status, data: r.headers.get('Content-Type')?.includes('application/json')?await r.json():new Uint8Array(await r.arrayBuffer()) };
    };
    const devices = [];
    for (const name of ['alice', 'bob']) {
      const device_id = crypto.randomUUID(); const keys = await Promise.all(['X25519', 'P256'].map(keyPair));
      const s = await call('/chat/v2/session', name, 'POST', { device_id, device_name: name });
      assert.equal(s.status, 200, JSON.stringify(s.data));
      const token = s.data.data.chat_token;
      const registration = await call(`/chat/v2/devices/${device_id}/keys`, token, 'POST', {
        expected_revision: '0', keys: keys.map(({ privateKey, ...key }) => key)
      });
      assert.equal(registration.status, 200, JSON.stringify(registration.data));
      devices.push({ ...s.data.data, token, keys });
    }
    const [a, b] = devices;
    const envelopes = [a, b].map(d => ({ target_subject: d.subject, target_device_id: d.device_id,
      algorithm: 'X25519', sender_key_id: a.keys[0].key_id, recipient_key_id: d.keys[0].key_id,
      nonce: base64(new Uint8Array(12)), ciphertext: base64(new Uint8Array(16)) }));
    const request = { client_msg_id: crypto.randomUUID(), to_subject: b.subject, client_sent_at_ms: Date.now(),
      sender_keyset_revision: '1', recipient_keyset_revision: '1', envelopes };
    const sent = await call('/chat/v2/messages', a.token, 'POST', request);
    assert.equal(sent.status, 200, JSON.stringify(sent.data));
    assert.equal((await call('/chat/v2/messages', a.token, 'POST', request)).data.data.message_id, sent.data.data.message_id);
    const received = await call('/chat/v2/sync?limit=1', b.token);
    assert.equal(received.status, 200, JSON.stringify(received.data));
    let page = received.data.data;
    while (page.has_more) page = (await call(`/chat/v2/sync?limit=1&cursor=${encodeURIComponent(page.next_cursor)}`, b.token)).data.data;
    const ack = await call('/chat/v2/sync/ack', b.token, 'POST', { cursor: page.next_cursor });
    assert.equal(ack.status, 200, JSON.stringify(ack.data));
    const read = await call(`/chat/v2/conversations/${sent.data.data.conversation_id}/read`, b.token, 'POST', {
      up_to_conversation_seq: sent.data.data.conversation_seq
    });
    assert.equal(read.status, 200, JSON.stringify(read.data));
    const rollback = await call(`/chat/v2/devices/${a.device_id}/keys`, a.token, 'POST', {
      expected_revision: '0', keys: (await Promise.all(['X25519', 'P256'].map(keyPair))).map(({ privateKey, ...k }) => k)
    });
    assert.equal(rollback.status, 409);
    assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM v2_messages').first()).n, 1);
    const good=r=>{assert.equal(r.status,200,JSON.stringify(r.data));return r.data.data;};
    const prefs=good(await call('/chat/v2/me/preferences',a.token,'PATCH',{expected_revision:'0',read_receipts:false,retention_days:7}));assert.equal(prefs.revision,'1');
    assert.equal((await call('/chat/v2/me/preferences',a.token,'PATCH',{expected_revision:'0'})).status,409);
    good(await call('/chat/v2/me/notifications',a.token,'PATCH',{expected_revision:'0',overrides:{quiet_hours:{timezone:'Asia/Shanghai',start:'23:00',end:'07:00',weekdays:[1,2,3,4,5,6,7]}}}));
    assert.equal(good(await call('/chat/v2/conversations',b.token)).unread_total,0);
    good(await call(`/chat/v2/devices/${a.device_id}/legacy`,a.token,'POST',{expected_revision:'0',key_revision:'1'}));
    good(await call('/chat/key','bob','POST',{userId:'bob',publicKey:b.keys[1].public_key}));
    assert.equal(good(await call('/chat/key/alice','bob')).publicKey,a.keys[1].public_key);
    const oldCipher=await encryptLegacy(b.keys[1].privateKey,a.keys[1].public_key,'P256','runtime android');
    good(await call('/chat/send','bob','POST',{to:'alice',msgId:'runtime-android',cipher:oldCipher,ts:Date.now()}));
    const event=good(await call('/chat/v2/sync',a.token)).events.find(e=>e.envelope?.protocol==='nu-chat-v1');
    assert.equal(await decryptLegacy(a.keys[1].privateKey,event.envelope.sender_public_key,'P256',event.envelope.cipher),'runtime android');
    good(await call(`/chat/v2/messages/${event.message_id}`,a.token,'DELETE'));
    assert.equal(good(await call('/chat/v2/history/filters',a.token)).filters[0].type,'hidden');
    const pack_id=crypto.randomUUID();const cipher=await createHistoryCipher(newRecoveryKey(),{owner:a.subject,pack_id,kind:'backup'});
    const chunk=await cipher.encryptChunk(0,new TextEncoder().encode('real private R2'));
    const pack=good(await call('/chat/v2/history/backups',a.token,'POST',{pack_id,expected_bytes:chunk.length,chunk_count:1,recovery_key_id:crypto.randomUUID()}));
    assert.equal(pack.state,'uploading');const base=`/chat/v2/history/backups/${pack_id}`;
    const sha=base64(await crypto.subtle.digest('SHA-256',chunk));
    good(await call(`${base}/chunks/0`,a.token,'PUT',chunk,{'X-Chunk-SHA256':sha}));
    const manifest=await cipher.manifest({records:1});good(await call(`${base}/complete`,a.token,'POST',{expected_revision:'1',manifest}));
    const downloaded=await call(`${base}/chunks/0`,a.token);assert.equal(downloaded.status,200);
    assert.equal(new TextDecoder().decode(await cipher.decryptChunk(0,downloaded.data)),'real private R2');
    const bucket=await mf.getR2Bucket('HISTORY_BUCKET');assert.equal((await bucket.list()).objects.length,1);
    good(await call(`${base}?expected_revision=2`,a.token,'DELETE'));assert.equal((await call(`${base}/chunks/0`,a.token)).status,410);
    good(await call(`/chat/v2/blocks/${b.subject}`,a.token,'PUT',{}));
    assert.equal((await call('/chat/send','bob','POST',{to:'alice',msgId:'blocked',cipher:oldCipher,ts:Date.now()})).status,409);
  } finally { await mf.dispose(); }
});
