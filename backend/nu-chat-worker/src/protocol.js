// Public client-side primitives too: no private material is sent to the relay.
import { base64, unbase64, hash } from './common.js';
export function aad(meta) {
  return new TextEncoder().encode(JSON.stringify(['nu-chat-v2', meta.sender_subject,
    meta.sender_device_id, meta.recipient_subject, meta.client_msg_id,
    meta.target_subject, meta.target_device_id, meta.algorithm,
    meta.sender_key_id, meta.recipient_key_id]));
}
async function messageKey(privateKey, peerSpki, meta) {
  const algorithm = meta.algorithm === 'X25519' ? { name: 'X25519' } : { name: 'ECDH', namedCurve: 'P-256' };
  const peer = await crypto.subtle.importKey('spki', unbase64(peerSpki, 1024), algorithm, false, []);
  const bits = await crypto.subtle.deriveBits({ ...algorithm, public: peer }, privateKey, 256);
  const input = await crypto.subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256',
    salt: await crypto.subtle.digest('SHA-256', aad(meta)), info: new TextEncoder().encode('nu-chat-v2') },
  input, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
export async function encrypt(privateKey, peerSpki, meta, plaintext, nonce = crypto.getRandomValues(new Uint8Array(12))) {
  if (new TextEncoder().encode(plaintext).length > 16384) throw new Error('plaintext too large');
  const key = await messageKey(privateKey, peerSpki, meta);
  const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad(meta), tagLength: 128 },
    key, new TextEncoder().encode(plaintext));
  return { nonce: base64(nonce), ciphertext: base64(encrypted) };
}
export async function decrypt(privateKey, peerSpki, meta, envelope) {
  const key = await messageKey(privateKey, peerSpki, meta);
  const clear = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unbase64(envelope.nonce, 12),
    additionalData: aad(meta), tagLength: 128 }, key, unbase64(envelope.ciphertext, 16400));
  return new TextDecoder('utf-8', { fatal: true }).decode(clear);
}
export const fingerprint = publicSpki => hash(publicSpki);

// Exact Android nu-chat-v1 codec. Intentionally no V2 AAD or salt substitution:
// a relay cannot upgrade an existing ciphertext without the user's private key.
async function legacyKey(privateKey, peerSpki, algorithm) {
  const spec=algorithm==='X25519'?{name:'X25519'}:{name:'ECDH',namedCurve:'P-256'};
  if(!['X25519','P256'].includes(algorithm))throw new Error('unsupported algorithm');
  const peer=await crypto.subtle.importKey('spki',unbase64(peerSpki,1024),spec,false,[]);
  const bits=await crypto.subtle.deriveBits({...spec,public:peer},privateKey,256);
  const input=await crypto.subtle.importKey('raw',bits,'HKDF',false,['deriveKey']);
  return crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:new Uint8Array(32),
    info:new TextEncoder().encode('nu-chat-v1')},input,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
}
export async function encryptLegacy(privateKey,peerSpki,algorithm,plaintext,nonce=crypto.getRandomValues(new Uint8Array(12))){
  const bytes=new TextEncoder().encode(plaintext);if(bytes.length>16384||nonce.length!==12)throw new Error('invalid plaintext or nonce');
  const key=await legacyKey(privateKey,peerSpki,algorithm);
  return `${base64(nonce)}:${base64(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,tagLength:128},key,bytes))}`;
}
export async function decryptLegacy(privateKey,peerSpki,algorithm,cipher){
  const parts=cipher.split(':');if(parts.length!==2)throw new Error('invalid cipher');
  const nonce=unbase64(parts[0],12);if(nonce.length!==12)throw new Error('invalid nonce');
  const key=await legacyKey(privateKey,peerSpki,algorithm);
  return new TextDecoder('utf-8',{fatal:true}).decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:nonce,tagLength:128},key,unbase64(parts[1],16400)));
}
