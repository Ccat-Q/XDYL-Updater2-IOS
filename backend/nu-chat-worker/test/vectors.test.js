// PUBLIC SYNTHETIC TEST PRIVATE KEYS. Never import these into a real account.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createPrivateKey,createPublicKey,diffieHellman,hkdfSync,createCipheriv,createHash} from 'node:crypto';
import {encrypt,decrypt,encryptLegacy,decryptLegacy} from '../src/protocol.js';
const vectors=JSON.parse(readFileSync(new URL('./crypto-vectors.json',import.meta.url),'utf8'));
for(const v of vectors)test(`fixed public vector ${v.algorithm}: V1 and V2 match WebCrypto/OpenSSL, both directions`,async()=>{
  const meta={sender_subject:'account:1',sender_device_id:'00000000-0000-4000-8000-000000000001',recipient_subject:'account:2',
    client_msg_id:'00000000-0000-4000-8000-000000000003',target_subject:'account:2',target_device_id:'00000000-0000-4000-8000-000000000002',
    algorithm:v.algorithm,sender_key_id:'00000000-0000-4000-8000-000000000004',recipient_key_id:'00000000-0000-4000-8000-000000000005'};
  const spec=v.algorithm==='X25519'?{name:'X25519'}:{name:'ECDH',namedCurve:'P-256'};
  const a=await crypto.subtle.importKey('pkcs8',Buffer.from(v.sender_pkcs8,'base64'),spec,false,['deriveBits']);
  const b=await crypto.subtle.importKey('pkcs8',Buffer.from(v.recipient_pkcs8,'base64'),spec,false,['deriveBits']);
  const plaintext='互通向量 🌊 / nu-chat',nonce=Uint8Array.from({length:12},(_,i)=>i);
  const envelope=await encrypt(a,v.recipient_spki,meta,plaintext,nonce);
  assert.equal(envelope.nonce,'AAECAwQFBgcICQoL');assert.equal(envelope.ciphertext,v.v2_ciphertext);
  assert.equal(await decrypt(b,v.sender_spki,meta,envelope),plaintext);
  assert.equal(await encryptLegacy(a,v.recipient_spki,v.algorithm,plaintext,nonce),v.v1);
  assert.equal(await decryptLegacy(b,v.sender_spki,v.algorithm,v.v1),plaintext);
  const shared=diffieHellman({privateKey:createPrivateKey({key:Buffer.from(v.sender_pkcs8,'base64'),format:'der',type:'pkcs8'}),
    publicKey:createPublicKey({key:Buffer.from(v.recipient_spki,'base64'),format:'der',type:'spki'})});
  const aad=Buffer.from(JSON.stringify(['nu-chat-v2',meta.sender_subject,meta.sender_device_id,meta.recipient_subject,meta.client_msg_id,
    meta.target_subject,meta.target_device_id,meta.algorithm,meta.sender_key_id,meta.recipient_key_id]));
  for(const version of [1,2]){
    const key=Buffer.from(hkdfSync('sha256',shared,version===1?Buffer.alloc(32):createHash('sha256').update(aad).digest(),Buffer.from(`nu-chat-v${version}`),32));
    const c=createCipheriv('aes-256-gcm',key,nonce);if(version===2)c.setAAD(aad);
    const cipher=Buffer.concat([c.update(plaintext,'utf8'),c.final(),c.getAuthTag()]).toString('base64');
    assert.equal(cipher,version===1?v.v1.split(':')[1]:v.v2_ciphertext);
  }
});
