import { fail, object, body, noBody, query, uuid, text, sequence, publicKey, unbase64,
  hash, canonical, base64, statement as q, rows, guard, atomic, rate, DAY } from './common.js';
import { sessionGuard, active } from './store.js';
import { readOpaque, signOpaque } from './cursor.js';

export const CHUNK=1048576;
export function recoveryLimits(env) {
  const value=(key,fallback)=>{const n=Number(env[key]??fallback);if(!Number.isSafeInteger(n)||n<CHUNK) fail(503,'NOT_CONFIGURED');return n;};
  const pack=value('HISTORY_MAX_PACK_BYTES',100*CHUNK),account=value('HISTORY_ACCOUNT_BYTES',500*CHUNK);
  const uploads=Number(env.HISTORY_MAX_UPLOADS??2);
  if(pack>account||pack>1024*CHUNK||!Number.isInteger(uploads)||uploads<1||uploads>10) fail(503,'NOT_CONFIGURED');
  return {chunk_bytes:CHUNK,max_pack_bytes:pack,account_bytes:account,max_uploads:uploads,backup_days:30,transfer_hours:24};
}
const publicPack=p=>({pack_id:p.pack_id,kind:p.kind,state:p.state,revision:String(p.revision),source_device:p.source_device,
  target_device:p.target_device,expected_bytes:p.expected_bytes,chunk_count:p.chunk_count,recovery_key_id:p.recovery_key_id,
  target_public_key:p.target_public_key,source_public_key:p.source_public_key,approval_proof:p.approval_proof,
  created_at_ms:p.created_at,expires_at_ms:p.expires_at,approval_expires_at_ms:p.approval_expires_at});
async function owned(db,id,kind,auth,now,allowExpired=false) {
  const p=await q(db,'SELECT * FROM v2_recovery_packs WHERE pack_id=?',id).first();
  if(!p||p.kind!==kind) fail(404,'PACK_NOT_FOUND');
  if(p.owner!==auth.subject) fail(403,'FORBIDDEN');
  if(kind==='transfer'&&![p.source_device,p.target_device].includes(auth.device_id)) {
    // A candidate may inspect/approve a pending transfer, but never download it.
    if(p.state!=='awaiting_approval'||!await q(db,'SELECT 1 FROM v2_transfer_candidates WHERE pack_id=? AND device_id=?',id,auth.device_id).first()) fail(403,'FORBIDDEN');
  }
  if(!allowExpired&&(p.expires_at<=now||(p.state==='awaiting_approval'&&p.approval_expires_at<=now)||['cancelled','expired','deleting','completed'].includes(p.state))) fail(410,'PACK_EXPIRED');
  return p;
}
function sizes(expected,count,limits) {
  if(!Number.isSafeInteger(expected)||expected<29||expected>limits.max_pack_bytes
      ||!Number.isInteger(count)||count!==Math.ceil(expected/CHUNK)) fail(400,'INVALID_REQUEST');
}
function packGuard(db,p,now,state='uploading') {
  return guard(db,`EXISTS(SELECT 1 FROM v2_recovery_packs WHERE pack_id=? AND revision=? AND state=? AND expires_at>?)`,p.pack_id,p.revision,state,now);
}
async function binary(req,max) {
  if((req.headers.get('Content-Type')||'').split(';')[0]!=='application/octet-stream'||!req.body) fail(415,'INVALID_REQUEST');
  const reader=req.body.getReader();const chunks=[];let n=0;
  try {while(true){const {done,value}=await reader.read();if(done)break;n+=value.length;if(n>max){await reader.cancel();fail(413,'PAYLOAD_TOO_LARGE');}chunks.push(value);}}
  finally{reader.releaseLock();}
  const out=new Uint8Array(n);let at=0;for(const c of chunks){out.set(c,at);at+=c.length;}return out;
}
async function filters(req,env,db,url,auth) {
  query(url,['cursor','limit']);await noBody(req);
  const limit=Number(url.searchParams.get('limit')??'200');if(!Number.isInteger(limit)||limit<1||limit>500)fail(400,'INVALID_REQUEST');
  const revision=String((await q(db,'SELECT revision FROM v2_filter_clock WHERE owner=?',auth.subject).first())?.revision??0);
  let after='';
  if(url.searchParams.has('cursor')){
    const c=await readOpaque(env,url.searchParams.get('cursor'));
    if(c.scope!=='history_filters'||c.owner!==auth.subject)fail(403,'FORBIDDEN');
    if(c.revision!==revision)fail(409,'FILTER_CHANGED');after=text(c.after,256);
  }
  const list=await rows(q(db,`WITH f AS(
    SELECT 'hidden:'||message_id AS key,'hidden' AS type,message_id AS target,NULL AS through_seq FROM v2_hidden WHERE owner=?
    UNION ALL SELECT 'clear:'||conversation_id,'clear',conversation_id,CAST(clear_seq AS TEXT) FROM v2_conversation_state WHERE owner=? AND clear_seq>0
    UNION ALL SELECT 'recall:'||message_id,'recall',message_id,NULL FROM v2_messages WHERE recalled_at IS NOT NULL AND(sender=? OR recipient=?))
    SELECT * FROM f WHERE key>? ORDER BY key LIMIT ?`,auth.subject,auth.subject,auth.subject,auth.subject,after,limit+1));
  const current=String((await q(db,'SELECT revision FROM v2_filter_clock WHERE owner=?',auth.subject).first())?.revision??0);
  if(current!==revision)fail(409,'FILTER_CHANGED');
  const page=list.slice(0,limit);
  return {ok:true,data:{revision,filters:page.map(({key,...r})=>r),has_more:list.length>limit,
    next_cursor:list.length>limit?await signOpaque(env,{scope:'history_filters',owner:auth.subject,revision,after:page.at(-1).key}):null}};
}
export async function recoveryRoute(req,env,db,url,auth,deps) {
  if(!url.pathname.startsWith('/chat/v2/history/'))return null;
  active(auth);const now=deps.now();const sg=()=>sessionGuard(db,auth,now);
  if(url.pathname==='/chat/v2/history/filters')return filters(req,env,db,url,auth);
  if(!env.HISTORY_BUCKET?.put)fail(503,'HISTORY_NOT_CONFIGURED');
  const limits=recoveryLimits(env);const bucket=env.HISTORY_BUCKET;
  if(url.pathname==='/chat/v2/history/quota'){
    query(url,[]);await noBody(req);
    const used=await q(db,'SELECT COALESCE(SUM(expected_bytes),0) AS reserved_bytes FROM v2_recovery_packs WHERE owner=? AND gc_done=0',auth.subject).first();
    return {ok:true,data:{...limits,...used}};
  }
  const m=url.pathname.match(/^\/chat\/v2\/history\/(backups|transfers)(?:\/([^/]+)(?:\/(approve|complete|ack|chunks)(?:\/([0-9]+))?)?)?$/);
  if(!m)fail(404,'NOT_FOUND');
  const kind=m[1]==='backups'?'backup':'transfer';
  if(!m[2]&&req.method==='GET'){
    query(url,['before','limit']);await noBody(req);const before=Number(url.searchParams.get('before')??Number.MAX_SAFE_INTEGER);
    const limit=Number(url.searchParams.get('limit')??'50');if(!Number.isSafeInteger(before)||!Number.isInteger(limit)||limit<1||limit>100)fail(400,'INVALID_REQUEST');
    // Listing uses immutable creation rowid, not timestamps that can collide.
    const list=await rows(q(db,`SELECT rowid AS position,* FROM v2_recovery_packs WHERE owner=? AND kind=? AND rowid<?
      AND (?='backup' OR source_device=? OR target_device=? OR pack_id IN(SELECT pack_id FROM v2_transfer_candidates WHERE device_id=?))
      ORDER BY rowid DESC LIMIT ?`,auth.subject,kind,before,kind,auth.device_id,auth.device_id,auth.device_id,limit+1));
    const page=list.slice(0,limit);
    return {ok:true,data:{packs:page.map(publicPack),has_more:list.length>limit,next_before:page.at(-1)?.position??null}};
  }
  if(!m[2]&&req.method==='POST'){
    query(url,[]);await rate(db,`history-create:${auth.subject}`,10,now);
    const b=object(await body(req),kind==='backup'?['pack_id','expected_bytes','chunk_count','recovery_key_id']:['pack_id','target_public_key'],kind==='transfer'?['max_bytes']:[]);
    const id=uuid(b.pack_id);const creationHash=await hash(canonical(b));
    const prior=await q(db,'SELECT * FROM v2_recovery_packs WHERE pack_id=?',id).first();
    if(prior){if(prior.owner!==auth.subject||prior.creator_device!==auth.device_id||prior.kind!==kind||prior.creation_hash!==creationHash)fail(409,'IDEMPOTENCY_CONFLICT');return {ok:true,data:publicPack(prior)};}
    const expected=kind==='backup'?b.expected_bytes:(b.max_bytes??limits.max_pack_bytes);const count=kind==='backup'?b.chunk_count:0;
    if(kind==='backup'){sizes(expected,count,limits);uuid(b.recovery_key_id);}else{
      if(!Number.isSafeInteger(expected)||expected<29||expected>limits.max_pack_bytes)fail(400,'INVALID_REQUEST');
      await publicKey('X25519',b.target_public_key);
    }
    const state=kind==='backup'?'uploading':'awaiting_approval';
    await atomic(db,[sg(),guard(db,`(SELECT COALESCE(SUM(expected_bytes),0) FROM v2_recovery_packs WHERE owner=? AND gc_done=0)+?<=?
      AND (SELECT COUNT(*) FROM v2_recovery_packs WHERE owner=? AND state IN('uploading','awaiting_approval') AND gc_done=0)<?`,auth.subject,expected,limits.account_bytes,auth.subject,limits.max_uploads),
      q(db,`INSERT INTO v2_recovery_packs(pack_id,owner,kind,source_device,target_device,creator_device,state,expected_bytes,chunk_count,
        recovery_key_id,target_public_key,created_at,expires_at,approval_expires_at,creation_hash)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,id,auth.subject,kind,kind==='backup'?auth.device_id:null,kind==='transfer'?auth.device_id:null,
      auth.device_id,state,expected,count,b.recovery_key_id??null,b.target_public_key??null,now,now+(kind==='backup'?30*DAY:DAY),kind==='transfer'?now+600000:null,creationHash),
      ...(kind==='transfer'?[q(db,`INSERT INTO v2_transfer_candidates(pack_id,device_id,key_revision)
        SELECT ?,device_id,key_revision FROM v2_devices WHERE subject=? AND active=1 AND revoked=0 AND device_id<>?`,id,auth.subject,auth.device_id)]:[])],'QUOTA_OR_UPLOAD_LIMIT');
    return {ok:true,data:publicPack(await q(db,'SELECT * FROM v2_recovery_packs WHERE pack_id=?',id).first())};
  }
  const id=uuid(m[2]);const action=m[3];query(url,action==='chunks'&&req.method==='GET'?[]:req.method==='DELETE'?['expected_revision']:[]);
  const p=await owned(db,id,kind,auth,now,req.method==='DELETE'||action==='ack');
  if(!action&&req.method==='GET'){
    await noBody(req);const chunks=await rows(q(db,'SELECT chunk_index,bytes,digest,state FROM v2_recovery_chunks WHERE pack_id=? ORDER BY chunk_index',id));
    return {ok:true,data:{...publicPack(p),chunks,manifest:p.state==='ready'?p.manifest:null,restore_filters:'/chat/v2/history/filters'}};
  }
  if(!action&&req.method==='DELETE'){
    await noBody(req);if(['cancelled','expired','completed','deleting'].includes(p.state))return {ok:true};
    const revision=sequence(url.searchParams.get('expected_revision'));
    await atomic(db,[sg(),guard(db,'EXISTS(SELECT 1 FROM v2_recovery_packs WHERE pack_id=? AND revision=?)',id,revision),
      q(db,"UPDATE v2_recovery_packs SET state='deleting',delete_reason='cancelled',revision=revision+1 WHERE pack_id=?",id)]);
    return {ok:true,data:{state:'deleting'}};
  }
  if(action==='approve'&&kind==='transfer'&&req.method==='POST'){
    const b=object(await body(req),['expected_revision','expected_bytes','chunk_count','source_public_key','approval_proof']);sequence(b.expected_revision);sizes(b.expected_bytes,b.chunk_count,limits);
    if(p.state!=='awaiting_approval'||p.target_device===auth.device_id||p.approval_expires_at<=now)fail(409,'APPROVAL_UNAVAILABLE');
    if(b.expected_bytes>p.expected_bytes)fail(409,'QUOTA_OR_UPLOAD_LIMIT');
    await publicKey('X25519',b.source_public_key);if(unbase64(b.approval_proof,32).length!==32)fail(400,'INVALID_REQUEST');
    await atomic(db,[sg(),guard(db,`EXISTS(SELECT 1 FROM v2_recovery_packs WHERE pack_id=? AND revision=? AND state='awaiting_approval' AND approval_expires_at>?)
      AND EXISTS(SELECT 1 FROM v2_transfer_candidates c JOIN v2_devices d ON d.device_id=c.device_id AND d.key_revision=c.key_revision WHERE c.pack_id=? AND c.device_id=? AND d.revoked=0 AND d.active=1)
      AND EXISTS(SELECT 1 FROM v2_devices WHERE device_id=? AND active=1 AND revoked=0)`,id,b.expected_revision,now,id,auth.device_id,p.target_device),
      q(db,`UPDATE v2_recovery_packs SET source_device=?,state='uploading',revision=revision+1,expected_bytes=?,chunk_count=?,source_public_key=?,approval_proof=? WHERE pack_id=?`,
      auth.device_id,b.expected_bytes,b.chunk_count,b.source_public_key,b.approval_proof,id)]);
    return {ok:true,data:publicPack(await q(db,'SELECT * FROM v2_recovery_packs WHERE pack_id=?',id).first())};
  }
  if(action==='chunks'&&m[4]!==undefined){
    const index=Number(m[4]);if(!Number.isSafeInteger(index)||index<0||index>=p.chunk_count)fail(400,'INVALID_REQUEST');
    if(req.method==='GET'){
      await noBody(req);if(p.state!=='ready'||(kind==='transfer'&&p.target_device!==auth.device_id))fail(409,'PACK_NOT_READY');
      const chunk=await q(db,"SELECT * FROM v2_recovery_chunks WHERE pack_id=? AND chunk_index=? AND state='ready'",id,index).first();if(!chunk)fail(404,'CHUNK_NOT_FOUND');
      const stored=await bucket.get(chunk.object_key);if(!stored)fail(503,'OBJECT_UNAVAILABLE');
      return new Response(stored.body,{headers:{'Content-Type':'application/octet-stream','Cache-Control':'no-store','Access-Control-Allow-Origin':'*','Access-Control-Expose-Headers':'X-Chunk-SHA256','X-Chunk-SHA256':chunk.digest}});
    }
    if(p.state!=='uploading'||p.source_device!==auth.device_id)fail(403,'FORBIDDEN');
    await rate(db,`history-upload:${auth.subject}`,120,now);
    const expected=index===p.chunk_count-1?p.expected_bytes-CHUNK*index:CHUNK;
    const bytes=await binary(req,CHUNK);if(bytes.length!==expected)fail(400,'CHUNK_SIZE_MISMATCH');
    const digest=base64(await crypto.subtle.digest('SHA-256',bytes));if(req.headers.get('X-Chunk-SHA256')!==digest)fail(400,'DIGEST_MISMATCH');
    const existing=await q(db,'SELECT * FROM v2_recovery_chunks WHERE pack_id=? AND chunk_index=?',id,index).first();
    if(existing&&(existing.digest!==digest||existing.bytes!==bytes.length))fail(409,'IDEMPOTENCY_CONFLICT');
    if(existing?.state==='ready')return {ok:true,data:{chunk_index:index,digest}};
    const key=`history/${id}/${index}`;
    await atomic(db,[sg(),packGuard(db,p,now),q(db,`INSERT INTO v2_recovery_chunks(pack_id,chunk_index,bytes,digest,object_key,state) VALUES(?,?,?,?,?,'writing')
      ON CONFLICT(pack_id,chunk_index) DO NOTHING`,id,index,bytes.length,digest,key)]);
    const reserved=await q(db,'SELECT digest FROM v2_recovery_chunks WHERE pack_id=? AND chunk_index=?',id,index).first();
    if(reserved.digest!==digest)fail(409,'IDEMPOTENCY_CONFLICT');
    // The row is reserved BEFORE R2 IO. A late write is compensated below and
    // the namespace scavenger also catches a process dying before compensation.
    try {
      await bucket.put(key,bytes,{httpMetadata:{contentType:'application/octet-stream'},customMetadata:{digest}});
      await atomic(db,[sg(),packGuard(db,p,now),q(db,"UPDATE v2_recovery_chunks SET state='ready' WHERE pack_id=? AND chunk_index=? AND digest=?",id,index,digest)]);
    }
    catch(e){
      const current=await q(db,'SELECT state FROM v2_recovery_packs WHERE pack_id=?',id).first();
      if(current&&!['uploading','ready'].includes(current.state)){
        try {await bucket.delete(key);}catch{
          await db.batch([q(db,`INSERT INTO v2_recovery_chunks(pack_id,chunk_index,bytes,digest,object_key,state) VALUES(?,?,?,?,?,'writing') ON CONFLICT(pack_id,chunk_index) DO NOTHING`,id,index,bytes.length,digest,key),
            q(db,'UPDATE v2_recovery_packs SET gc_done=0 WHERE pack_id=?',id)]);
        }
      }
      throw e;
    }
    return {ok:true,data:{chunk_index:index,digest}};
  }
  if(action==='complete'&&req.method==='POST'){
    const b=object(await body(req),['expected_revision','manifest']);sequence(b.expected_revision);text(b.manifest,65536);
    if(new TextEncoder().encode(b.manifest).length>65536)fail(413,'PAYLOAD_TOO_LARGE');
    let manifest;try{manifest=JSON.parse(b.manifest);}catch{fail(400,'INVALID_MANIFEST');}
    object(manifest,['format','salt','sealed_manifest']);
    if(manifest.format!=='nu-chat-history/1'||unbase64(manifest.salt,32).length!==32||unbase64(manifest.sealed_manifest,49152).length<28)fail(400,'INVALID_MANIFEST');
    if(p.source_device!==auth.device_id)fail(403,'FORBIDDEN');
    if(p.state==='ready'&&p.manifest===b.manifest)return {ok:true,data:publicPack(p)};
    await atomic(db,[sg(),guard(db,`EXISTS(SELECT 1 FROM v2_recovery_packs WHERE pack_id=? AND revision=? AND state='uploading' AND expires_at>?)
      AND (SELECT COUNT(*) FROM v2_recovery_chunks WHERE pack_id=? AND state='ready')=?
      AND (SELECT SUM(bytes) FROM v2_recovery_chunks WHERE pack_id=? AND state='ready')=?`,id,b.expected_revision,now,id,p.chunk_count,id,p.expected_bytes),
      q(db,"UPDATE v2_recovery_packs SET state='ready',manifest=?,revision=revision+1 WHERE pack_id=?",b.manifest,id)]);
    return {ok:true,data:publicPack(await q(db,'SELECT * FROM v2_recovery_packs WHERE pack_id=?',id).first())};
  }
  if(action==='ack'&&kind==='transfer'&&req.method==='POST'){
    const b=object(await body(req),['expected_revision','filter_revision']);sequence(b.expected_revision);sequence(b.filter_revision);
    if(p.target_device!==auth.device_id)fail(403,'FORBIDDEN');
    if(p.state==='completed')return {ok:true,data:{state:'completed'}};
    if(p.expires_at<=now)fail(410,'PACK_EXPIRED');
    const current=String((await q(db,'SELECT revision FROM v2_filter_clock WHERE owner=?',auth.subject).first())?.revision??0);
    if(current!==b.filter_revision)fail(409,'FILTER_CHANGED');
    await atomic(db,[sg(),guard(db,`EXISTS(SELECT 1 FROM v2_recovery_packs WHERE pack_id=? AND revision=? AND state='ready')
      AND COALESCE((SELECT revision FROM v2_filter_clock WHERE owner=?),0)=CAST(? AS INTEGER)`,id,b.expected_revision,auth.subject,b.filter_revision),
      q(db,"UPDATE v2_recovery_packs SET state='completed',completed_at=?,revision=revision+1 WHERE pack_id=?",now,id)]);
    return {ok:true,data:{state:'completed'}};
  }
  fail(405,'METHOD_NOT_ALLOWED');
}

export async function sweepRecovery(env,db,now) {
  if(!env.HISTORY_BUCKET?.delete)return;
  const packs=await rows(q(db,`SELECT * FROM v2_recovery_packs WHERE gc_done=0 AND
    (state IN('deleting','completed') OR expires_at<=? OR (state='awaiting_approval' AND approval_expires_at<=?)) LIMIT 20`,now,now));
  for(const p of packs){
    await q(db,`UPDATE v2_recovery_packs SET state=CASE WHEN state='completed' THEN state ELSE 'deleting' END,
      delete_reason=CASE WHEN expires_at<=? OR (state='awaiting_approval' AND approval_expires_at<=?) THEN 'expired' ELSE delete_reason END,
      revision=revision+1 WHERE pack_id=? AND gc_done=0`,now,now,p.pack_id).run();
    const chunks=await rows(q(db,'SELECT object_key FROM v2_recovery_chunks WHERE pack_id=?',p.pack_id));
    // Delete objects before releasing reservations; a failed R2 delete is retried.
    for(let i=0;i<chunks.length;i+=100)await env.HISTORY_BUCKET.delete(chunks.slice(i,i+100).map(c=>c.object_key));
    await db.batch([q(db,'DELETE FROM v2_recovery_chunks WHERE pack_id=?',p.pack_id),
      q(db,`UPDATE v2_recovery_packs SET gc_done=1,manifest=NULL,state=CASE WHEN state='completed' THEN state ELSE delete_reason END WHERE pack_id=?`,p.pack_id),
      q(db,'DELETE FROM v2_transfer_candidates WHERE pack_id=?',p.pack_id)]);
  }
  if(env.HISTORY_BUCKET.list){
    const state=await q(db,'SELECT cursor FROM v2_blob_gc_state WHERE id=1').first();
    const listed=await env.HISTORY_BUCKET.list({prefix:'history/',limit:1000,...(state?.cursor?{cursor:state.cursor}:{})});
    const keys=listed.objects.map(o=>o.key);
    if(keys.length){
      const tracked=await rows(q(db,`SELECT c.object_key FROM v2_recovery_chunks c JOIN v2_recovery_packs p ON p.pack_id=c.pack_id
        WHERE c.object_key IN(SELECT value FROM json_each(?)) AND p.gc_done=0 AND p.state IN('uploading','ready') AND p.expires_at>?`,JSON.stringify(keys),now));
      const keep=new Set(tracked.map(r=>r.object_key));const orphan=keys.filter(k=>!keep.has(k));
      for(let i=0;i<orphan.length;i+=100)await env.HISTORY_BUCKET.delete(orphan.slice(i,i+100));
    }
    await q(db,'UPDATE v2_blob_gc_state SET cursor=? WHERE id=1',listed.truncated?listed.cursor:null).run();
  }
}
