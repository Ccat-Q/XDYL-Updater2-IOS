import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fixture,keyPair} from './helpers.js';
import {encryptLegacy,decryptLegacy} from '../src/protocol.js';
import {createWorker as productionWorker} from '../production-snapshots/2026-11-15T094436Z/src/index.js';

const good = response => { assert.equal(response.status,200,JSON.stringify(response.data)); return response.data.data; };

test('verified production source-map snapshot preserves all original module hashes',()=>{
  const root=new URL('../production-snapshots/2026-11-15T094436Z/',import.meta.url);
  const manifest=JSON.parse(readFileSync(new URL('manifest.json',root),'utf8'));
  assert.equal(manifest.modules.length,11);
  assert.equal(manifest.versions[0].percentage,100);
  for(const module of manifest.modules){
    assert.match(module.path,/^src\/[a-z0-9_-]+\.js$/);
    const hash=createHash('sha256').update(readFileSync(new URL(module.path,root))).digest('hex');
    assert.equal(hash,module.sha256,module.path);
  }
});

test('platform prefixes and POST GET-alias preserve V2 error shape and authentication',async()=>{
  const f=await fixture();
  assert.equal(good(await f.call('/iOS/chat/v2/capabilities')).protocol,'nu-chat-v2');
  assert.equal((await f.call('/Android/chat/ping')).data.protocol,'legacy-d1');
  const denied=await f.call('/iOS/chat/v2/session','invalid','POST',{device_id:crypto.randomUUID(),device_name:'test'});
  assert.equal(denied.status,401);assert.equal(typeof denied.data.error.code,'string');
  const owner=await f.user('owner',1);
  const devices=good(await f.call('/iOS/chat/v2/devices?__alias=1',owner.token,'POST',{}));
  assert.equal(devices.devices.length,1);
  assert.equal((await f.call('/Android/chat/ping?__alias=1',null,'POST',{})).status,200);
  assert.equal((await f.call('/iOS/chat/v2/capabilities?token=forbidden')).status,400);
});

test('production device registration records stable identity and returns server-owned platform mapping',async()=>{
  const f=await fixture();f.identities.set('main-owner',{id:1,username:'owner'});
  const body={device_code:'a'.repeat(64),platform:'ios',app_version:'test-1'};
  const first=good(await f.call('/iOS/chat/device/register','main-owner','POST',body));
  assert.equal(first.entry_prefix,'/iOS');assert.equal(first.protocol,'v2');
  f.tick(1000);
  const second=good(await f.call('/Android/chat/device/register','main-owner','POST',{...body,platform:'android'}));
  assert.equal(second.entry_prefix,'/Android');assert.equal(second.protocol,'v1-legacy');
  const rows=f.db.raw.prepare('SELECT subject,platform,first_seen,last_seen FROM device_registry').all();
  assert.equal(rows.length,1);assert.equal(rows[0].subject,'account:1');assert.equal(rows[0].platform,'android');
  assert.equal(rows[0].last_seen-rows[0].first_seen,1000);
  assert.equal((await f.call('/chat/device/register','main-owner','POST',{...body,device_code:'invalid'})).status,400);
  assert.equal((await f.call('/chat/device/register',null,'POST',body)).status,401);
});

test('production opaque key backups are account-scoped across PUT/POST lookup and deletion',async()=>{
  const f=await fixture();f.identities.set('main-owner',{id:1,username:'owner'});f.identities.set('main-other',{id:2,username:'other'});
  const body={pwd_blob:'opaque-password-envelope',code_blob:'opaque-recovery-envelope',code_hash:'b'.repeat(64),kdf:'test-kdf'};
  good(await f.call('/Android/chat/key-backup','main-owner','PUT',body));
  const fetched=good(await f.call('/Android/chat/key-backup','main-owner'));
  assert.equal(fetched.pwd_blob,body.pwd_blob);assert.equal(fetched.code_blob,body.code_blob);
  assert.equal((await f.call('/chat/key-backup','main-other')).status,404);
  assert.equal((await f.call('/chat/key-backup/lookup','main-owner','POST',{code_hash:'c'.repeat(64)})).status,404);
  assert.equal(good(await f.call('/chat/key-backup/lookup','main-owner','POST',{code_hash:body.code_hash})).code_blob,body.code_blob);
  good(await f.call('/chat/key-backup','main-owner','POST',{...body,pwd_blob:'updated-opaque-envelope'}));
  assert.equal(good(await f.call('/chat/key-backup','main-owner')).pwd_blob,'updated-opaque-envelope');
  assert.equal((await f.call('/chat/key-backup','main-owner','DELETE')).status,200);
  assert.equal((await f.call('/chat/key-backup','main-owner')).status,404);
});

test('captured production curve regression is reproducible; workspace keeps P256 lookup and envelope consistent',async()=>{
  for(const [factory,isProduction] of [[productionWorker,true],[undefined,false]]){
    const f=await fixture({},factory);
    const old=await keyPair('P256');f.identities.set('main-android',{id:1,username:'android'});
    good(await f.call('/Android/chat/key','main-android','POST',{publicKey:old.public_key}));
    const ios=await f.user('iphone',2);
    good(await f.call(`/iOS/chat/v2/devices/${ios.device_id}/legacy`,ios.token,'POST',{expected_revision:'0',key_revision:'1'}));
    const p256=ios.keys.find(k=>k.algorithm==='P256');const x25519=ios.keys.find(k=>k.algorithm==='X25519');
    const lookup=good(await f.call('/Android/chat/key/iphone','main-android'));
    assert.equal(lookup.publicKey,p256.public_key);
    const clear='synthetic interoperability fixture';
    const cipher=await encryptLegacy(old.privateKey,lookup.publicKey,'P256',clear);
    assert.equal((await f.call('/Android/chat/send','main-android','POST',{to:'iphone',msgId:'regression-fixture',cipher,ts:f.now()})).status,200);
    const event=good(await f.call('/iOS/chat/v2/sync',ios.token)).events.find(e=>e.type==='message');
    assert.equal(event.envelope.protocol,'nu-chat-v1');assert.equal(event.envelope.algorithm,'P256');
    assert.equal(event.envelope.cipher,cipher);
    if(isProduction){
      assert.equal(event.envelope.own_key_id,x25519.key_id);
      assert.equal(event.envelope.recipient_public_key,x25519.public_key);
      await assert.rejects(decryptLegacy(x25519.privateKey,old.public_key,'X25519',cipher));
    } else {
      assert.equal(event.envelope.own_key_id,p256.key_id);
      assert.equal(event.envelope.recipient_public_key,p256.public_key);
      assert.equal(await decryptLegacy(p256.privateKey,old.public_key,'P256',event.envelope.cipher),clear);
    }
  }
});
