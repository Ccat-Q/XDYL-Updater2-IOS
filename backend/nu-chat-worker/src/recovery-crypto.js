// Frontend reference implementation. These functions are NEVER called with a
// user's recovery/private key by the relay. Test keys are synthetic only.
import { base64,unbase64,canonical } from './common.js';
const utf8=new TextEncoder();
export const newRecoveryKey=()=>base64(crypto.getRandomValues(new Uint8Array(32)));
export const newPairingSecret=newRecoveryKey;
function context(meta){return ['nu-chat-history/1',meta.owner,meta.pack_id,meta.kind];}
async function historyKey(root,meta,salt){
  const raw=unbase64(root,32);if(raw.length!==32||salt.length!==32)throw new Error('invalid key or salt');
  const input=await crypto.subtle.importKey('raw',raw,'HKDF',false,['deriveKey']);
  return crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt,info:utf8.encode(JSON.stringify(context(meta)))},input,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
}
async function seal(key,aad,bytes){
  const nonce=crypto.getRandomValues(new Uint8Array(12));
  const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:utf8.encode(aad),tagLength:128},key,bytes));
  const out=new Uint8Array(nonce.length+cipher.length);out.set(nonce);out.set(cipher,nonce.length);return out;
}
async function open(key,aad,bytes){
  if(bytes.length<28)throw new Error('invalid sealed data');
  return new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:utf8.encode(aad),tagLength:128},key,bytes.slice(12)));
}
export async function createHistoryCipher(root,meta,salt=crypto.getRandomValues(new Uint8Array(32))){
  const key=await historyKey(root,meta,salt);
  return {
    salt:base64(salt),
    encryptChunk:(index,bytes)=>{if(!Number.isInteger(index)||index<0||bytes.length>1048548)throw new Error('invalid chunk');return seal(key,JSON.stringify([...context(meta),'chunk',index]),bytes);},
    decryptChunk:(index,bytes)=>open(key,JSON.stringify([...context(meta),'chunk',index]),bytes),
    async manifest(data){
      const sealed=await seal(key,JSON.stringify([...context(meta),'manifest']),utf8.encode(canonical(data)));
      return JSON.stringify({format:'nu-chat-history/1',salt:base64(salt),sealed_manifest:base64(sealed)});
    },
    async openManifest(raw){const m=JSON.parse(raw);if(m.format!=='nu-chat-history/1'||m.salt!==base64(salt))throw new Error('invalid manifest');return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await open(key,JSON.stringify([...context(meta),'manifest']),unbase64(m.sealed_manifest,49152))));}
  };
}
export function pairingContext(meta){return canonical({owner:meta.owner,pack_id:meta.pack_id,source_device:meta.source_device,
  target_device:meta.target_device,source_public_key:meta.source_public_key,target_public_key:meta.target_public_key});}
export async function approvalProof(secret,meta){
  const key=await crypto.subtle.importKey('raw',unbase64(secret,32),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return base64(await crypto.subtle.sign('HMAC',key,utf8.encode(pairingContext(meta))));
}
export async function transferRoot(privateKey,peerPublicKey,pairingSecret,meta,proof){
  const key=await crypto.subtle.importKey('raw',unbase64(pairingSecret,32),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  if(!await crypto.subtle.verify('HMAC',key,unbase64(proof,32),utf8.encode(pairingContext(meta))))throw new Error('pairing verification failed');
  const peer=await crypto.subtle.importKey('spki',unbase64(peerPublicKey,1024),{name:'X25519'},false,[]);
  const shared=await crypto.subtle.deriveBits({name:'X25519',public:peer},privateKey,256);
  const input=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveBits']);
  const salt=await crypto.subtle.digest('SHA-256',unbase64(pairingSecret,32));
  return base64(await crypto.subtle.deriveBits({name:'HKDF',hash:'SHA-256',salt,info:utf8.encode(`nu-chat-transfer/1:${pairingContext(meta)}`)},input,256));
}
export function applyRestoreFilters(records,filters){
  const hidden=new Set(filters.filter(f=>f.type==='hidden').map(f=>f.target));
  const recalled=new Set(filters.filter(f=>f.type==='recall').map(f=>f.target));
  const clear=new Map(filters.filter(f=>f.type==='clear').map(f=>[f.target,BigInt(f.through_seq)]));
  const seen=new Set();
  return records.filter(r=>{
    if(!r.message_id||!r.conversation_id||typeof r.conversation_seq!=='string'||!/^\d+$/.test(r.conversation_seq))throw new Error('invalid archive record');
    if(seen.has(r.message_id)||hidden.has(r.message_id)||recalled.has(r.message_id)||BigInt(r.conversation_seq)<=(clear.get(r.conversation_id)??-1n))return false;
    seen.add(r.message_id);return true;
  });
}
