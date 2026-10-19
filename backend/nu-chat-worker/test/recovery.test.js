import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,MemoryR2,keyPair} from './helpers.js';
import {base64,DAY} from '../src/common.js';
import {sweepRecovery,CHUNK} from '../src/recovery.js';
import {createHistoryCipher,newRecoveryKey,newPairingSecret,approvalProof,transferRoot,applyRestoreFilters} from '../src/recovery-crypto.js';
const good=r=>{assert.equal(r.status,200,JSON.stringify(r.data));return r.data.data;};
const digest=async bytes=>base64(await crypto.subtle.digest('SHA-256',bytes));
const path=(kind,id)=>`/chat/v2/history/${kind}/${id}`;
async function backup(f,u,bytes=new Uint8Array(64).fill(5)){
  const id=crypto.randomUUID();const meta={owner:u.subject,pack_id:id,kind:'backup'};
  const root=newRecoveryKey();const cipher=await createHistoryCipher(root,meta);
  const sealed=await cipher.encryptChunk(0,bytes);const b={pack_id:id,expected_bytes:sealed.length,chunk_count:1,recovery_key_id:crypto.randomUUID()};
  const pack=good(await f.call('/chat/v2/history/backups',u.token,'POST',b));
  return {id,root,cipher,bytes,sealed,b,pack,base:path('backups',id)};
}
async function upload(f,u,p){return f.call(`${p.base}/chunks/0`,u.token,'PUT',p.sealed,{'X-Chunk-SHA256':await digest(p.sealed)});}
async function complete(f,u,p,revision='1'){
  const manifest=await p.cipher.manifest({format:'nu-chat-records/1',chunks:[{index:0,digest:await digest(p.sealed)}],records:1});
  return {response:await f.call(`${p.base}/complete`,u.token,'POST',{expected_revision:revision,manifest}),manifest};
}

test('encrypted manual backup roundtrip, resume/digests, ownership, immutable chunks and no live events',async()=>{
  const f=await fixture({HISTORY_BUCKET:new MemoryR2()});const a=await f.user('alice',1),b=await f.user('bob',2);const p=await backup(f,a);
  good(await f.call('/chat/v2/history/backups',a.token,'POST',p.b));
  assert.equal((await f.call('/chat/v2/history/backups',a.token,'POST',{...p.b,recovery_key_id:crypto.randomUUID()})).status,409);
  assert.equal((await f.call(`${p.base}/chunks/0`,a.token)).status,409);
  assert.equal((await f.call(p.base,b.token)).status,403);
  assert.equal((await f.call(`${p.base}/chunks/0`,a.token,'PUT',p.sealed,{'X-Chunk-SHA256':base64(new Uint8Array(32))})).status,400);
  good(await upload(f,a,p));good(await upload(f,a,p));
  const changed=p.sealed.slice();changed[20]^=1;
  assert.equal((await f.call(`${p.base}/chunks/0`,a.token,'PUT',changed,{'X-Chunk-SHA256':await digest(changed)})).status,409);
  assert.equal(good(await f.call(p.base,a.token)).chunks[0].state,'ready');
  const {response,manifest}=await complete(f,a,p);assert.equal(good(response).state,'ready');
  good(await f.call(`${p.base}/complete`,a.token,'POST',{expected_revision:'1',manifest}));
  const a2=await f.user('alice',1);const got=await f.call(`${p.base}/chunks/0`,a2.token);assert.equal(got.status,200);
  assert.deepEqual(await p.cipher.decryptChunk(0,got.data),p.bytes);
  assert.equal((await p.cipher.openManifest(good(await f.call(p.base,a2.token)).manifest)).records,1);
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_messages').get().n,0);
  // Only new device key registration creates an account-keyset event.
  assert.equal(f.db.raw.prepare("SELECT COUNT(*) AS n FROM v2_events WHERE type!='keyset_changed'").get().n,0);
  assert.equal((await f.call(`${p.base}/chunks/0`,a.token,'PUT',p.sealed,{'X-Chunk-SHA256':await digest(p.sealed)})).status,403);
});

test('backup concurrent upload limit and byte quota are atomic; configured limits are enforced',async()=>{
  const bucket=new MemoryR2();const f=await fixture({HISTORY_BUCKET:bucket,HISTORY_MAX_PACK_BYTES:CHUNK,HISTORY_ACCOUNT_BYTES:CHUNK,HISTORY_MAX_UPLOADS:2});
  const a=await f.user('alice',1);const p=await backup(f,a);good(await upload(f,a,p));await backup(f,a);
  const b={pack_id:crypto.randomUUID(),expected_bytes:29,chunk_count:1,recovery_key_id:crypto.randomUUID()};
  assert.equal((await f.call('/chat/v2/history/backups',a.token,'POST',b)).status,409);
  good(await f.call(`${p.base}?expected_revision=1`,a.token,'DELETE'));await sweepRecovery(f.env,f.db,f.now());
  assert.equal((await f.call('/chat/v2/history/backups',a.token,'POST',{...b,expected_bytes:CHUNK})).status,409);
  good(await f.call('/chat/v2/history/backups',a.token,'POST',{...b,expected_bytes:CHUNK-p.sealed.length}));
  assert.equal(good(await f.call('/chat/v2/history/quota',a.token)).reserved_bytes,CHUNK);
});

test('pack deletion requires CAS and releases quota only after R2 deletion, transient failure retries and orphan scavenging',async()=>{
  const bucket=new MemoryR2();const f=await fixture({HISTORY_BUCKET:bucket});const a=await f.user('alice',1);const p=await backup(f,a);good(await upload(f,a,p));
  assert.equal((await f.call(p.base,a.token,'DELETE')).status,400);
  assert.equal((await f.call(`${p.base}?expected_revision=0`,a.token,'DELETE')).status,409);
  good(await f.call(`${p.base}?expected_revision=1`,a.token,'DELETE'));
  assert.equal(good(await f.call('/chat/v2/history/quota',a.token)).reserved_bytes,p.sealed.length);
  const del=bucket.delete.bind(bucket);bucket.delete=async()=>{throw new Error('simulated R2 failure');};
  await assert.rejects(sweepRecovery(f.env,f.db,f.now()));assert.equal(good(await f.call('/chat/v2/history/quota',a.token)).reserved_bytes,p.sealed.length);
  bucket.delete=del;await bucket.put('history/orphan/0',new Uint8Array(32));await sweepRecovery(f.env,f.db,f.now());
  assert.equal(bucket.objects.size,0);assert.equal(good(await f.call('/chat/v2/history/quota',a.token)).reserved_bytes,0);
});

test('late R2 upload after cancellation compensates and cannot resurrect cancelled object',async()=>{
  const bucket=new MemoryR2();const f=await fixture({HISTORY_BUCKET:bucket});const a=await f.user('alice',1);const p=await backup(f,a);
  let resume,started;const gate=new Promise(r=>{resume=r;});const entered=new Promise(r=>{started=r;});const put=bucket.put.bind(bucket);
  bucket.put=async(...args)=>{started();await gate;await put(...args);};
  const pending=upload(f,a,p);await entered;
  good(await f.call(`${p.base}?expected_revision=1`,a.token,'DELETE'));await sweepRecovery(f.env,f.db,f.now());resume();
  assert.equal((await pending).status,409);assert.equal(bucket.objects.size,0);
  assert.equal(good(await f.call('/chat/v2/history/quota',a.token)).reserved_bytes,0);
});

test('trusted device transfer approval, client E2EE pairing, filters ACK, GC, no server private key',async()=>{
  const f=await fixture({HISTORY_BUCKET:new MemoryR2()});const old=await f.user('alice',1),target=await f.user('alice',1),intruder=await f.user('bob',2);
  const sourceKey=await keyPair('X25519'),targetKey=await keyPair('X25519'),secret=newPairingSecret();const id=crypto.randomUUID();const base=path('transfers',id);
  good(await f.call('/chat/v2/history/transfers',target.token,'POST',{pack_id:id,target_public_key:targetKey.public_key,max_bytes:1000}));
  const tooNew=await f.user('alice',1);assert.equal((await f.call(base,tooNew.token)).status,403);assert.equal((await f.call(base,intruder.token)).status,403);
  const meta={owner:old.subject,pack_id:id,source_device:old.device_id,target_device:target.device_id,source_public_key:sourceKey.public_key,target_public_key:targetKey.public_key};
  const proof=await approvalProof(secret,meta);
  const sourceRoot=await transferRoot(sourceKey.privateKey,targetKey.public_key,secret,meta,proof);
  const targetRoot=await transferRoot(targetKey.privateKey,sourceKey.public_key,secret,meta,proof);assert.equal(sourceRoot,targetRoot);
  const cipher=await createHistoryCipher(sourceRoot,{owner:old.subject,pack_id:id,kind:'transfer'});const sealed=await cipher.encryptChunk(0,new TextEncoder().encode('history'));
  good(await f.call(`${base}/approve`,old.token,'POST',{expected_revision:'1',expected_bytes:sealed.length,chunk_count:1,source_public_key:sourceKey.public_key,approval_proof:proof}));
  assert.equal((await f.call(`${base}/chunks/0`,target.token,'PUT',sealed,{'X-Chunk-SHA256':await digest(sealed)})).status,403);
  good(await f.call(`${base}/chunks/0`,old.token,'PUT',sealed,{'X-Chunk-SHA256':await digest(sealed)}));
  const manifest=await cipher.manifest({records:1});good(await f.call(`${base}/complete`,old.token,'POST',{expected_revision:'2',manifest}));
  const got=await f.call(`${base}/chunks/0`,target.token);assert.equal(new TextDecoder().decode(await cipher.decryptChunk(0,got.data)),'history');
  assert.equal((await f.call(`${base}/chunks/0`,old.token)).status,409);
  assert.equal((await f.call(`${base}/ack`,target.token,'POST',{expected_revision:'3',filter_revision:'9'})).status,409);
  good(await f.call(`${base}/ack`,target.token,'POST',{expected_revision:'3',filter_revision:'0'}));
  good(await f.call(`${base}/ack`,target.token,'POST',{expected_revision:'3',filter_revision:'0'}));await sweepRecovery(f.env,f.db,f.now());
  assert.equal(good(await f.call('/chat/v2/history/quota',target.token)).reserved_bytes,0);
  assert.equal(f.db.raw.prepare('SELECT COUNT(*) AS n FROM v2_messages').get().n,0);
});

test('approval and backup expiration never renew via login/download; revoked source cancels transfer',async()=>{
  const f=await fixture({HISTORY_BUCKET:new MemoryR2()});const source=await f.user('alice',1),target=await f.user('alice',1);const p=await backup(f,source);good(await upload(f,source,p));await complete(f,source,p);
  const id=crypto.randomUUID();good(await f.call('/chat/v2/history/transfers',target.token,'POST',{pack_id:id,target_public_key:(await keyPair('X25519')).public_key}));
  f.tick(600001);assert.equal((await f.call(path('transfers',id),source.token)).status,410);await sweepRecovery(f.env,f.db,f.now());
  f.tick(30*DAY);const fresh=await f.user('alice',1);
  assert.equal((await f.call(p.base,fresh.token)).status,410);await sweepRecovery(f.env,f.db,f.now());assert.equal(f.env.HISTORY_BUCKET.objects.size,0);
  const newId=crypto.randomUUID();const t=await f.user('alice',1);good(await f.call('/chat/v2/history/transfers',t.token,'POST',{pack_id:newId,target_public_key:(await keyPair('X25519')).public_key}));
  good(await f.call(`/chat/v2/devices/${t.device_id}`,fresh.token,'DELETE'));assert.equal(f.db.raw.prepare('SELECT state FROM v2_recovery_packs WHERE pack_id=?').get(newId).state,'deleting');
});

test('archive crypto rejects wrong recovery key, changed owner/pack/index, tampered manifest and pairing substitution; restore dedups',async()=>{
  const root=newRecoveryKey(),meta={owner:'account:1',pack_id:crypto.randomUUID(),kind:'backup'};
  const c=await createHistoryCipher(root,meta),bytes=await c.encryptChunk(0,new Uint8Array([1,2,3]));
  assert.deepEqual(await c.decryptChunk(0,bytes),new Uint8Array([1,2,3]));await assert.rejects(c.decryptChunk(1,bytes));
  const bad=bytes.slice();bad[20]^=1;await assert.rejects(c.decryptChunk(0,bad));
  for(const [r,m]of [[newRecoveryKey(),meta],[root,{...meta,owner:'account:2'}],[root,{...meta,pack_id:crypto.randomUUID()}]]){
    const other=await createHistoryCipher(r,m,Uint8Array.from(atob(c.salt),x=>x.charCodeAt(0)));await assert.rejects(other.decryptChunk(0,bytes));
  }
  const manifest=JSON.parse(await c.manifest({records:2}));manifest.sealed_manifest=base64(new Uint8Array(32));await assert.rejects(c.openManifest(JSON.stringify(manifest)));
  const a=await keyPair('X25519'),b=await keyPair('X25519');const secret=newPairingSecret();const m={owner:'account:1',pack_id:meta.pack_id,source_device:'s',target_device:'t',source_public_key:a.public_key,target_public_key:b.public_key};const proof=await approvalProof(secret,m);
  await assert.rejects(transferRoot(a.privateKey,b.public_key,secret,{...m,target_device:'evil'},proof));
  const record=(message_id,conversation_seq)=>({message_id,conversation_id:'c',conversation_seq});
  assert.deepEqual(applyRestoreFilters([record('a','1'),record('b','2'),record('c','3'),record('d','4'),record('d','4')],[{type:'clear',target:'c',through_seq:'1'},{type:'hidden',target:'b'},{type:'recall',target:'c'}]).map(r=>r.message_id),['d']);
});

test('full 1MiB binary chunk bypasses JSON size limit safely; failed R2 writes resume and incomplete packs cannot complete',async()=>{
  const bucket=new MemoryR2();const f=await fixture({HISTORY_BUCKET:bucket});const a=await f.user('alice',1);
  const id=crypto.randomUUID(),base=path('backups',id);const cipher=await createHistoryCipher(newRecoveryKey(),{owner:a.subject,pack_id:id,kind:'backup'});
  const chunks=[await cipher.encryptChunk(0,new Uint8Array(CHUNK-28).fill(9)),await cipher.encryptChunk(1,new Uint8Array([7]))];
  assert.equal(chunks[0].length,CHUNK);assert.equal(chunks[1].length,29);
  good(await f.call('/chat/v2/history/backups',a.token,'POST',{pack_id:id,expected_bytes:CHUNK+29,chunk_count:2,recovery_key_id:crypto.randomUUID()}));
  const oversized=new Uint8Array(CHUNK+1);
  assert.equal((await f.call(`${base}/chunks/0`,a.token,'PUT',oversized,{'X-Chunk-SHA256':await digest(oversized)})).status,413);
  const put=bucket.put.bind(bucket);bucket.put=async()=>{throw new Error('simulated write outage');};
  assert.equal((await f.call(`${base}/chunks/0`,a.token,'PUT',chunks[0],{'X-Chunk-SHA256':await digest(chunks[0])})).status,503);
  assert.equal(good(await f.call(base,a.token)).chunks[0].state,'writing');bucket.put=put;
  good(await f.call(`${base}/chunks/0`,a.token,'PUT',chunks[0],{'X-Chunk-SHA256':await digest(chunks[0])}));
  const manifest=await cipher.manifest({records:1,chunks:[{index:0,digest:await digest(chunks[0])},{index:1,digest:await digest(chunks[1])}]});
  assert.equal((await f.call(`${base}/complete`,a.token,'POST',{expected_revision:'1',manifest})).status,409);
  good(await f.call(`${base}/chunks/1`,a.token,'PUT',chunks[1],{'X-Chunk-SHA256':await digest(chunks[1])}));
  good(await f.call(`${base}/complete`,a.token,'POST',{expected_revision:'1',manifest}));
  for(let i=0;i<2;i++){const got=await f.call(`${base}/chunks/${i}`,a.token);assert.equal(got.status,200);assert.deepEqual(await cipher.decryptChunk(i,got.data),i===0?new Uint8Array(CHUNK-28).fill(9):new Uint8Array([7]));}
});
