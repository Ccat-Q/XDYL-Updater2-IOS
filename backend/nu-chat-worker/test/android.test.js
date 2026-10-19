import test from 'node:test';
import assert from 'node:assert/strict';
import {createPrivateKey,createPublicKey,diffieHellman,hkdfSync,createCipheriv,createDecipheriv} from 'node:crypto';
import {fixture,keyPair} from './helpers.js';
import {encryptLegacy,decryptLegacy} from '../src/protocol.js';

const good=r=>{assert.equal(r.status,200,JSON.stringify(r.data));return r.data.data;};
// Independent implementation of Android's ECDH/HKDF/AES contract using OpenSSL
// primitives, not the WebCrypto reference used by the V2 frontend.
async function androidKey(own,remote){
  const privateKey=createPrivateKey({key:Buffer.from(await crypto.subtle.exportKey('pkcs8',own.privateKey)),format:'der',type:'pkcs8'});
  const publicKey=createPublicKey({key:Buffer.from(remote,'base64'),format:'der',type:'spki'});
  return Buffer.from(hkdfSync('sha256',diffieHellman({privateKey,publicKey}),Buffer.alloc(32),Buffer.from('nu-chat-v1'),32));
}
async function androidEncrypt(own,remote,text){const nonce=Buffer.alloc(12,7);const c=createCipheriv('aes-256-gcm',await androidKey(own,remote),nonce);const bytes=Buffer.concat([c.update(text,'utf8'),c.final(),c.getAuthTag()]);return `${nonce.toString('base64')}:${bytes.toString('base64')}`;}
async function androidDecrypt(own,remote,cipher){const [n,c]=cipher.split(':').map(b=>Buffer.from(b,'base64'));const d=createDecipheriv('aes-256-gcm',await androidKey(own,remote),n);d.setAuthTag(c.subarray(-16));return Buffer.concat([d.update(c.subarray(0,-16)),d.final()]).toString('utf8');}
async function oldUser(f,name,id,algorithm){const key=await keyPair(algorithm);const mainToken=`main-${name}`;f.identities.set(mainToken,{id,username:name});good(await f.call('/chat/key',mainToken,'POST',{userId:name,publicKey:key.public_key}));return {username:name,key,mainToken,subject:`account:${id}`};}
async function enable(f,u){return good(await f.call(`/chat/v2/devices/${u.device_id}/legacy`,u.token,'POST',{expected_revision:'0',key_revision:'1'}));}

for(const algorithm of ['X25519','P256'])test(`old Android ↔ V2 primary device ${algorithm}: real bidirectional decryption, paged pull/read and privacy`,async()=>{
  const f=await fixture();const old=await oldUser(f,'android',1,algorithm);const modern=await f.user('iphone',2);await enable(f,modern);
  const lookup=good(await f.call('/chat/key/iphone',old.mainToken));const local=modern.keys.find(k=>k.algorithm===algorithm);
  assert.equal(lookup.publicKey,local.public_key);
  const clear='安卓 → iOS 🌊';const cipher=await androidEncrypt(old.key,lookup.publicKey,clear);
  const request={from:'android',to:'iphone',msgId:'android-message',cipher,ts:f.now()};
  const sent=await f.call('/chat/send',old.mainToken,'POST',request);assert.equal(sent.status,200,JSON.stringify(sent.data));
  assert.equal((await f.call('/chat/send',old.mainToken,'POST',request)).data.duplicate,true);
  assert.equal((await f.call('/chat/send',old.mainToken,'POST',{...request,ts:f.now()+1})).status,409);
  const events=good(await f.call('/chat/v2/sync',modern.token));const m=events.events.find(e=>e.type==='message');
  assert.equal(m.envelope.protocol,'nu-chat-v1');assert.equal(m.envelope.algorithm,algorithm);
  assert.equal(m.envelope.own_key_id,local.key_id);
  assert.equal(await decryptLegacy(local.privateKey,m.envelope.sender_public_key,algorithm,m.envelope.cipher),clear);
  good(await f.call('/chat/v2/sync/ack',modern.token,'POST',{cursor:events.next_cursor}));
  good(await f.call(`/chat/v2/conversations/${m.conversation_id}/read`,modern.token,'POST',{up_to_conversation_seq:m.conversation_seq}));
  assert.equal(good(await f.call('/chat/read?peerId=iphone',old.mainToken)).peer_upto,sent.data.seq);
  const response='iOS → 安卓 🌊';const sendBack={client_msg_id:crypto.randomUUID(),to_username:'android',
    cipher:await encryptLegacy(local.privateKey,old.key.public_key,algorithm,response),ts:f.now(),
    sender_key_id:local.key_id,recipient_public_key:old.key.public_key};
  const back=await f.call('/chat/v2/legacy/messages',modern.token,'POST',sendBack);assert.equal(back.status,200,JSON.stringify(back.data));
  const pulled=await f.call(`/chat/pull?cursor=${sent.data.seq}&limit=200`,old.mainToken);
  assert.equal(pulled.status,200,JSON.stringify(pulled.data));assert.equal(pulled.data.data.length,1);
  assert.equal(await androidDecrypt(old.key,local.public_key,pulled.data.data[0].cipher),response);
  good(await f.call('/chat/read',old.mainToken,'POST',{peerId:'iphone',upto:pulled.data.data[0].seq}));
  assert.equal(good(await f.call('/chat/v2/conversations',modern.token)).unread_total,0);
  good(await f.call(`/chat/v2/messages/${m.message_id}`,modern.token,'DELETE'));
  // The old peer's copy remains; an own-account hide must not delete both sides.
  assert.equal((await f.call('/chat/pull?cursor=0',old.mainToken)).data.data.length,2);
  const ownBack=f.db.raw.prepare('SELECT m.message_id FROM v2_messages m WHERE sender=?').get(modern.subject);
  good(await f.call(`/chat/v2/messages/${ownBack.message_id}/recall`,modern.token,'POST',{}));
  assert.equal((await f.call('/chat/pull?cursor=0',old.mainToken)).data.data.length,1);
  good(await f.call(`/chat/v2/blocks/${old.subject}`,modern.token,'PUT',{}));
  assert.equal((await f.call('/chat/send',old.mainToken,'POST',{...request,msgId:'blocked'})).status,409);
});

test('legacy binding is explicit, CAS/idempotent, never hijacks old Android keys or claims unavailable curves',async()=>{
  const f=await fixture();const native=await f.user('native',1);const old=await oldUser(f,'old',2,'P256');
  const protocols=good(await f.call('/chat/v2/users/native/protocols',native.token));assert.deepEqual(protocols.protocols,['nu-chat-v2']);
  assert.deepEqual(good(await f.call('/chat/v2/users/old/protocols',native.token)).protocols,['nu-chat-v1']);
  assert.equal((await f.call(`/chat/v2/devices/${native.device_id}/legacy`,native.token,'POST',{expected_revision:'9',key_revision:'1'})).status,409);
  await enable(f,native);await enable(f,native);
  const native2=await f.user('native',1);
  assert.equal((await f.call(`/chat/v2/devices/${native2.device_id}/legacy`,native2.token,'POST',{expected_revision:'1',key_revision:'1'})).status,409);
  assert.equal((await f.call('/chat/key',native.mainToken,'POST',{publicKey:(await keyPair('X25519')).public_key})).status,409);
  const oldModern=await f.user('old',2);
  assert.equal((await f.call(`/chat/v2/devices/${oldModern.device_id}/legacy`,oldModern.token,'POST',{expected_revision:'0',key_revision:'1'})).status,409);
  const x=await oldUser(f,'other',3,'X25519');
  assert.equal((await f.call('/chat/key/old',x.mainToken)).status,409);
  assert.equal((await f.call('/chat/key/old','invalid-token')).status,401);
  good(await f.call(`/chat/v2/devices/${native.device_id}`,native.token,'DELETE'));
  assert.equal((await f.call('/chat/key/native',old.mainToken)).status,409);
  assert.deepEqual(good(await f.call('/chat/v2/users/native/protocols',native2.token)).protocols,['nu-chat-v2']);
});

test('legacy sends are transactional under concurrency and filters advance numeric cursors',async()=>{
  const f=await fixture();const old=await oldUser(f,'old',1,'X25519');const modern=await f.user('new',2);await enable(f,modern);
  const cipher=await androidEncrypt(old.key,modern.keys[0].public_key,'test');const b={to:'new',msgId:'same',cipher,ts:f.now()};
  const responses=await Promise.all(Array.from({length:10},()=>f.call('/chat/send',old.mainToken,'POST',b)));
  for(const r of responses)assert.equal(r.status,200,JSON.stringify(r.data));
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_messages').get().n,1);
  const own=await f.user('old',1);
  const m=f.db.raw.prepare('SELECT * FROM v2_messages').get();good(await f.call(`/chat/v2/messages/${m.message_id}`,own.token,'DELETE'));
  const page=await f.call('/chat/pull?cursor=0&limit=1',old.mainToken);assert.deepEqual(page.data.data,[]);assert.ok(page.data.next_cursor>0);
});

test('username recycling never transfers linked history/read ownership, imported unbound history is quarantined',async()=>{
  const f=await fixture();const previous=await oldUser(f,'recycled',1,'X25519'),peer=await oldUser(f,'peer',2,'X25519');
  const cipher=await androidEncrypt(peer.key,previous.key.public_key,'previous account private history');
  const sent=await f.call('/chat/send',peer.mainToken,'POST',{to:'recycled',msgId:'old-owner',cipher,ts:f.now()});assert.equal(sent.status,200);
  await f.user('renamed',1);const replacement=await f.user('recycled',3);
  assert.equal((await f.call('/chat/key/recycled',peer.mainToken)).status,409);
  good(await f.call('/chat/key',replacement.mainToken,'POST',{publicKey:replacement.keys[0].public_key,expectedPublicKey:previous.key.public_key}));
  assert.deepEqual((await f.call('/chat/pull',replacement.mainToken)).data.data,[]);
  assert.equal((await f.call('/chat/read',replacement.mainToken,'POST',{peerId:'peer',upto:sent.data.seq})).status,400);
  f.db.raw.prepare('INSERT INTO messages(msg_id,from_user,to_user,cipher,ts,created_at) VALUES(?,?,?,?,?,?)').run('imported','peer','recycled',cipher,f.now(),f.now());
  const page=await f.call('/chat/pull',replacement.mainToken);assert.deepEqual(page.data.data,[]);assert.ok(page.data.next_cursor>sent.data.seq);
});

test('primary key rotation fails closed until explicit rebind; stale sender key IDs cannot be reused',async()=>{
  const f=await fixture();const modern=await f.user('new',1),old=await oldUser(f,'old',2,'X25519');await enable(f,modern);
  const keys=await Promise.all(['X25519','P256'].map(keyPair));
  good(await f.call(`/chat/v2/devices/${modern.device_id}/keys`,modern.token,'POST',{expected_revision:'1',keys:keys.map(({privateKey,...k})=>k)}));
  assert.equal((await f.call('/chat/key/new',old.mainToken)).status,409);
  good(await f.call(`/chat/v2/devices/${modern.device_id}/legacy`,modern.token,'POST',{expected_revision:'1',key_revision:'2'}));
  assert.equal(good(await f.call('/chat/key/new',old.mainToken)).publicKey,keys[0].public_key);
  const request={client_msg_id:crypto.randomUUID(),to_username:'old',cipher:await encryptLegacy(keys[0].privateKey,old.key.public_key,'X25519','rotated'),
    ts:f.now(),sender_key_id:modern.keys[0].key_id,recipient_public_key:old.key.public_key};
  assert.equal((await f.call('/chat/v2/legacy/messages',modern.token,'POST',request)).status,409);
  assert.equal((await f.call('/chat/v2/legacy/messages',modern.token,'POST',{...request,sender_key_id:keys[0].key_id})).status,200);
});
