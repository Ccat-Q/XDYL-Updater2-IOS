// Android contract fixed at UNSA-studio/xdyl 36d3a8c. No decryption/transcoding.
import { fail,object,body,noBody,query,uuid,sequence,username,text,publicKey,hash,canonical,
  unbase64,statement as q,guard,atomic,rate,DAY } from './common.js';
import { sessionGuard,active,bundle } from './store.js';
import { deliveryGuard } from './social.js';
import { barkEnabled } from './bark.js';
export async function legacyAlgorithm(key){
  for(const algorithm of ['X25519','P256'])try{await publicKey(algorithm,key);return algorithm;}catch{}
  fail(409,'LEGACY_KEY_UNSUPPORTED');
}
export async function legacyPeer(db,name,algorithm){
  const binding=await q(db,`SELECT a.subject,b.*,d.active,d.revoked,d.key_revision AS current_revision
    FROM v2_accounts a JOIN v2_legacy_bindings b ON b.subject=a.subject JOIN v2_devices d ON d.device_id=b.device_id
    WHERE a.username=?`,name).first();
  if(binding?.enabled){
    if(!binding.active||binding.revoked||binding.current_revision!==binding.key_revision)fail(409,'LEGACY_DEVICE_UNAVAILABLE');
    const key=await q(db,'SELECT key_id,algorithm,public_key FROM v2_keys WHERE device_id=? AND revision=? AND algorithm=?',binding.device_id,binding.key_revision,algorithm??binding.default_algorithm).first();
    if(!key)fail(409,'LEGACY_ALGORITHM_MISMATCH');
    return {...key,subject:binding.subject,device_id:binding.device_id};
  }
  const key=await q(db,'SELECT public_key FROM users WHERE username=?',name).first();
  if(!key)fail(404,'USER_NOT_FOUND');
  const found=await legacyAlgorithm(key.public_key);if(algorithm&&algorithm!==found)fail(409,'LEGACY_ALGORITHM_MISMATCH');
  const account=await q(db,'SELECT subject FROM v2_accounts WHERE username=?',name).first();
  const owned=await q(db,'SELECT subject FROM v2_legacy_users WHERE username=?',name).first();
  if(!account||owned?.subject!==account.subject)fail(409,'LEGACY_IDENTITY_UNBOUND');
  return {public_key:key.public_key,algorithm:found,subject:account.subject,device_id:null,key_id:null};
}
export async function legacySend(db,env,from,b,now,authGuard=null,sourceKeyId=null){
  const msgId=b.msgId;const bodyHash=await hash(canonical(b));
  const old=await q(db,`SELECT m.*,l.request_hash FROM messages m LEFT JOIN v2_legacy_link l ON l.legacy_seq=m.seq WHERE m.from_user=? AND m.msg_id=?`,from,msgId).first();
  if(old){
    if(old.to_user!==b.to||old.cipher!==b.cipher||old.ts!==b.ts||(old.request_hash&&old.request_hash!==bodyHash))fail(409,'IDEMPOTENCY_CONFLICT');
    return {ok:true,duplicate:true,seq:old.seq};
  }
  const sender=await legacyPeer(db,from);
  await rate(db,`send:${sender.subject}`,30,now);
  let selected=sender;
  if(sourceKeyId){
    const key=await q(db,'SELECT algorithm FROM v2_keys WHERE key_id=? AND device_id=?',sourceKeyId,sender.device_id).first();
    if(!key)fail(409,'KEYSET_CHANGED');selected=await legacyPeer(db,from,key.algorithm);
    if(selected.key_id!==sourceKeyId)fail(409,'KEYSET_CHANGED');
  }
  const recipient=await legacyPeer(db,b.to,selected.algorithm);
  if(b.recipient_public_key!==undefined&&b.recipient_public_key!==recipient.public_key)fail(409,'KEYSET_CHANGED');
  const algorithm=selected.algorithm;
  if(!selected.subject||!recipient.subject){
    // Imported pre-V2 accounts must authenticate once to establish stable IDs.
    // Never guess a stable identity from nickname or someone else's profile.
    fail(409,'LEGACY_IDENTITY_UNBOUND');
  }
  const [a,z]=[selected.subject,recipient.subject].sort();if(a===z)fail(400,'INVALID_REQUEST');
  const id=crypto.randomUUID();const sourceDevice=selected.device_id??`legacy:${from}`;
  const stmts=[...(authGuard?[authGuard]:[]),deliveryGuard(db,selected.subject,recipient.subject),
    // Public-key selection and message commit share a transaction/CAS boundary.
    guard(db,`(NOT EXISTS(SELECT 1 FROM v2_legacy_bindings b JOIN v2_accounts a ON a.subject=b.subject WHERE a.username=? AND b.enabled=1)
      AND EXISTS(SELECT 1 FROM users WHERE username=? AND public_key=?)) OR EXISTS(
      SELECT 1 FROM v2_legacy_bindings b JOIN v2_keys k ON k.device_id=b.device_id AND k.revision=b.key_revision
      JOIN v2_accounts a ON a.subject=b.subject JOIN v2_devices d ON d.device_id=b.device_id
      WHERE a.username=? AND b.enabled=1 AND d.revoked=0 AND d.active=1 AND d.key_revision=b.key_revision AND k.public_key=?)`,from,from,selected.public_key,from,selected.public_key),
    guard(db,`(NOT EXISTS(SELECT 1 FROM v2_legacy_bindings b JOIN v2_accounts a ON a.subject=b.subject WHERE a.username=? AND b.enabled=1)
      AND EXISTS(SELECT 1 FROM users WHERE username=? AND public_key=?)) OR EXISTS(
      SELECT 1 FROM v2_legacy_bindings b JOIN v2_keys k ON k.device_id=b.device_id AND k.revision=b.key_revision
      JOIN v2_accounts a ON a.subject=b.subject JOIN v2_devices d ON d.device_id=b.device_id
      WHERE a.username=? AND b.enabled=1 AND d.revoked=0 AND d.active=1 AND d.key_revision=b.key_revision AND k.public_key=?)`,b.to,b.to,recipient.public_key,b.to,recipient.public_key),
    q(db,`INSERT INTO messages(msg_id,from_user,to_user,cipher,ts,created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(from_user,msg_id) DO NOTHING`,msgId,from,b.to,b.cipher,b.ts,now),
    guard(db,'EXISTS(SELECT 1 FROM messages WHERE from_user=? AND msg_id=? AND to_user=? AND cipher=? AND ts=?)',from,msgId,b.to,b.cipher,b.ts),
    q(db,'INSERT INTO v2_conversations(conversation_id,a,b) VALUES(?,?,?) ON CONFLICT(a,b) DO NOTHING',crypto.randomUUID(),a,z),
    q(db,`INSERT INTO v2_messages(message_id,client_msg_id,sender,sender_device,recipient,conversation_id,request_hash,accepted_at,expires_at)
      SELECT ?,?,?,?,?,conversation_id,?,?,? FROM v2_conversations WHERE a=? AND b=?
      ON CONFLICT(sender,sender_device,client_msg_id) DO NOTHING`,id,msgId,selected.subject,sourceDevice,recipient.subject,bodyHash,now,now+30*DAY,a,z),
    guard(db,'EXISTS(SELECT 1 FROM v2_messages WHERE sender=? AND sender_device=? AND client_msg_id=? AND request_hash=?)',selected.subject,sourceDevice,msgId,bodyHash),
    q(db,`INSERT INTO v2_legacy_link(legacy_seq,message_id,request_hash,algorithm,sender_public_key,recipient_public_key)
      SELECT l.seq,m.message_id,?,?,?,? FROM messages l JOIN v2_messages m ON m.sender=? AND m.sender_device=? AND m.client_msg_id=?
      WHERE l.from_user=? AND l.msg_id=? ON CONFLICT(legacy_seq) DO NOTHING`,bodyHash,algorithm,selected.public_key,recipient.public_key,selected.subject,sourceDevice,msgId,from,msgId)];
  for(const owner of [selected.subject,recipient.subject])stmts.push(q(db,`INSERT INTO v2_copies(owner,message_id,expires_at)
    SELECT ?,m.message_id,MIN(m.expires_at,m.accepted_at+COALESCE((SELECT retention_days FROM v2_preferences WHERE subject=?),30)*?)
    FROM v2_messages m JOIN v2_legacy_link l ON l.message_id=m.message_id JOIN messages old ON old.seq=l.legacy_seq
    WHERE old.from_user=? AND old.msg_id=? ON CONFLICT(owner,message_id) DO NOTHING`,owner,owner,DAY,from,msgId));
  for(const target of [selected,recipient])if(target.device_id){
    stmts.push(q(db,`INSERT INTO v2_events(device_id,dedup,type,message_id,payload,expires_at)
      SELECT ?,'msg:'||m.message_id,'message',m.message_id,json_object('type','message','message_id',m.message_id,
      'client_msg_id',m.client_msg_id,'conversation_id',m.conversation_id,'conversation_seq',CAST(m.seq AS TEXT),
      'sender_subject',m.sender,'sender_device_id',m.sender_device,'recipient_subject',m.recipient,'accepted_at_ms',m.accepted_at,
      'expires_at_ms',cp.expires_at,'envelope',json_object('protocol','nu-chat-v1','algorithm',l.algorithm,'cipher',old.cipher,
      'sender_public_key',l.sender_public_key,'recipient_public_key',l.recipient_public_key,'own_key_id',?)),cp.expires_at
      FROM v2_messages m JOIN v2_legacy_link l ON l.message_id=m.message_id JOIN messages old ON old.seq=l.legacy_seq
      JOIN v2_copies cp ON cp.message_id=m.message_id AND cp.owner=? WHERE old.from_user=? AND old.msg_id=?
      ON CONFLICT(device_id,dedup) DO NOTHING`,target.device_id,target.key_id,target.subject,from,msgId));
    if(target===recipient&&barkEnabled(env))stmts.push(q(db,`INSERT INTO v2_outbox(notification_id,device_id,message_id,binding_version,next_at,created_at)
      SELECT ?,?,l.message_id,k.version,?,? FROM v2_legacy_link l JOIN messages old ON old.seq=l.legacy_seq
      JOIN v2_bark k ON k.device_id=? AND k.enabled=1 WHERE old.from_user=? AND old.msg_id=?
      ON CONFLICT(message_id,device_id) DO NOTHING`,crypto.randomUUID(),target.device_id,now,now,target.device_id,from,msgId));
  }
  await atomic(db,stmts,'DELIVERY_OR_KEY_CONFLICT');
  const result=await q(db,'SELECT seq FROM messages WHERE from_user=? AND msg_id=?',from,msgId).first();
  const committed=await q(db,'SELECT message_id FROM v2_legacy_link WHERE legacy_seq=?',result.seq).first();
  return {ok:true,duplicate:committed.message_id!==id,seq:result.seq};
}
export async function androidRoute(req,env,db,url,auth,deps){
  const now=deps.now();const path=url.pathname;let match=path.match(/^\/chat\/v2\/devices\/([^/]+)\/legacy$/);
  if(match){
    query(url,[]);active(auth);const id=uuid(match[1]);if(id!==auth.device_id)fail(403,'FORBIDDEN');
    const current=await q(db,'SELECT * FROM v2_legacy_bindings WHERE subject=?',auth.subject).first();
    if(req.method==='GET'){await noBody(req);return {ok:true,data:{enabled:!!current?.enabled,device_id:current?.device_id??null,revision:String(current?.revision??0),primary_device_only:true}};}
    const b=object(await body(req),['expected_revision','key_revision'],['default_algorithm']);sequence(b.expected_revision);sequence(b.key_revision);
    const keys=await bundle(db,auth.subject);const device=keys.devices.find(d=>d.device_id===id);
    if(!device||device.key_revision!==b.key_revision)fail(409,'KEYSET_CHANGED');
    const algorithm=b.default_algorithm??'X25519';const key=device.keys.find(k=>k.algorithm===algorithm);if(!key)fail(400,'UNSUPPORTED_ALGORITHM');
    if(current?.device_id===id&&String(current.key_revision)===b.key_revision&&current.default_algorithm===algorithm
      &&(b.expected_revision===String(current.revision)||BigInt(b.expected_revision)+1n===BigInt(current.revision)))
      return {ok:true,data:{enabled:true,device_id:id,revision:String(current.revision),primary_device_only:true}};
    if(b.expected_revision!==String(current?.revision??0))fail(409,'REVISION_CONFLICT');
    if(current&&current.device_id!==id)fail(409,'LEGACY_IDENTITY_ALREADY_BOUND');
    const old=await q(db,'SELECT public_key FROM users WHERE username=?',auth.username).first();
    if(!current&&old&&!device.keys.some(k=>k.public_key===old.public_key))fail(409,'LEGACY_ACCOUNT_ALREADY_IN_USE');
    await atomic(db,[sessionGuard(db,auth,now),guard(db,`COALESCE((SELECT revision FROM v2_legacy_bindings WHERE subject=?),0)=CAST(? AS INTEGER)
      AND NOT EXISTS(SELECT 1 FROM users WHERE username=? AND public_key<>?)
      AND EXISTS(SELECT 1 FROM v2_devices WHERE device_id=? AND key_revision=? AND active=1 AND revoked=0)`,auth.subject,b.expected_revision,auth.username,old?.public_key??key.public_key,id,b.key_revision),
      q(db,`INSERT INTO v2_legacy_bindings(subject,device_id,key_revision,default_algorithm) VALUES(?,?,?,?)
        ON CONFLICT(subject) DO UPDATE SET key_revision=excluded.key_revision,default_algorithm=excluded.default_algorithm,revision=revision+1`,auth.subject,id,b.key_revision,algorithm),
      q(db,'INSERT INTO users(username,public_key,updated_at) VALUES(?,?,?) ON CONFLICT(username) DO UPDATE SET public_key=excluded.public_key,updated_at=excluded.updated_at',auth.username,key.public_key,now),
      q(db,'INSERT INTO v2_legacy_users(username,subject) VALUES(?,?) ON CONFLICT(username) DO UPDATE SET subject=excluded.subject',auth.username,auth.subject)]);
    return {ok:true,data:{enabled:true,device_id:id,revision:String(Number(current?.revision??0)+1),primary_device_only:true}};
  }
  match=path.match(/^\/chat\/v2\/users\/([^/]+)\/protocols$/);
  if(match){
    query(url,[]);await noBody(req);let name;try{name=decodeURIComponent(match[1]);}catch{fail(400,'INVALID_REQUEST');}username(name);
    const account=await q(db,'SELECT subject FROM v2_accounts WHERE username=?',name).first();
    if(!account)fail(404,'USER_NOT_FOUND');
    const native=await bundle(db,account.subject);const keys=[];
    for(const alg of ['X25519','P256'])try{const key=await legacyPeer(db,name,alg);keys.push({algorithm:key.algorithm,public_key:key.public_key});}
    catch(e){if(!['USER_NOT_FOUND','LEGACY_ALGORITHM_MISMATCH','LEGACY_DEVICE_UNAVAILABLE','LEGACY_IDENTITY_UNBOUND'].includes(e.code))throw e;}
    const binding=await q(db,'SELECT device_id FROM v2_legacy_bindings WHERE subject=?',account.subject).first();
    return {ok:true,data:{username:name,subject:account.subject,protocols:[...(native.devices.length?['nu-chat-v2']:[]),...(keys.length?['nu-chat-v1']:[])],
      legacy_public_keys:keys,legacy_primary_device:binding?.device_id??null}};
  }
  if(path==='/chat/v2/legacy/messages'){
    query(url,[]);active(auth);const b=object(await body(req),['client_msg_id','to_username','cipher','ts','sender_key_id','recipient_public_key']);
    uuid(b.client_msg_id);uuid(b.sender_key_id);username(b.to_username);text(b.cipher,24000);
    if(!Number.isSafeInteger(b.ts)||b.ts<0)fail(400,'INVALID_REQUEST');
    const parts=b.cipher.split(':');if(parts.length!==2||unbase64(parts[0],12).length!==12||unbase64(parts[1],16400).length<16)fail(400,'INVALID_REQUEST');
    const binding=await q(db,'SELECT device_id FROM v2_legacy_bindings WHERE subject=? AND enabled=1',auth.subject).first();
    if(binding?.device_id!==auth.device_id)fail(403,'LEGACY_PRIMARY_DEVICE_REQUIRED');
    return legacySend(db,env,auth.username,{from:auth.username,to:b.to_username,msgId:`v2:${auth.device_id}:${b.client_msg_id}`,
      cipher:b.cipher,ts:b.ts,recipient_public_key:b.recipient_public_key,sender_key_id:b.sender_key_id},now,sessionGuard(db,auth,now),b.sender_key_id);
  }
  return null;
}
