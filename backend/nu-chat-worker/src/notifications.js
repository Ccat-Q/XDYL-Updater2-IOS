import { fail, object, body, noBody, query, uuid, sequence, statement as q, rows, guard, atomic } from './common.js';
import { conversation, sessionGuard } from './store.js';
import { visible, notifyAccount } from './social.js';

const dayNames = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
export function validateNotificationConfig(config) {
  object(config, [], ['enabled','muted','mute_until_ms','quiet_hours']);
  for (const k of ['enabled','muted']) if (config[k] !== undefined && typeof config[k] !== 'boolean') fail(400,'INVALID_REQUEST');
  if (config.mute_until_ms !== undefined && (!Number.isSafeInteger(config.mute_until_ms) || config.mute_until_ms < 0)) fail(400,'INVALID_REQUEST');
  if (config.quiet_hours !== undefined && config.quiet_hours !== null) {
    const h = object(config.quiet_hours,['timezone','start','end','weekdays']);
    if (typeof h.timezone !== 'string' || h.timezone.length > 64) fail(400,'INVALID_REQUEST');
    try { new Intl.DateTimeFormat('en',{timeZone:h.timezone}).format(); } catch { fail(400,'INVALID_TIMEZONE'); }
    for (const k of ['start','end']) if (typeof h[k] !== 'string' || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(h[k])) fail(400,'INVALID_REQUEST');
    const minutes = s => Number(s.slice(0,2))*60+Number(s.slice(3));
    const duration = (minutes(h.end)-minutes(h.start)+1440)%1440;
    if (!duration || duration > 1380 || !Array.isArray(h.weekdays) || !h.weekdays.length || h.weekdays.length>7
        || new Set(h.weekdays).size !== h.weekdays.length || h.weekdays.some(d=>!Number.isInteger(d)||d<1||d>7)) fail(400,'INVALID_REQUEST');
  }
  return config;
}
export function quietUntil(hours, now) {
  if (!hours) return 0;
  const fmt = new Intl.DateTimeFormat('en-US',{timeZone:hours.timezone,weekday:'short',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
  const minutes = s=>Number(s.slice(0,2))*60+Number(s.slice(3));
  const start = minutes(hours.start), end = minutes(hours.end);
  const inside = time=>{
    const p=Object.fromEntries(fmt.formatToParts(time).map(x=>[x.type,x.value]));
    let day=dayNames.indexOf(p.weekday)||7; const minute=Number(p.hour)*60+Number(p.minute);
    if(start<end) return hours.weekdays.includes(day)&&minute>=start&&minute<end;
    if(minute<end) day=day===1?7:day-1;
    return hours.weekdays.includes(day)&&(minute>=start||minute<end);
  };
  if(!inside(now)) return 0;
  let high=now+900000;
  while(inside(high)&&high<now+3*86400000) high+=900000;
  if(inside(high)) fail(400,'INVALID_QUIET_HOURS');
  let low=high-900000;
  while(high-low>1000){const mid=Math.floor((low+high)/2);if(inside(mid)) low=mid;else high=mid;}
  return Math.floor(high/60000)*60000;
}
export async function notificationConfig(db, owner, device, conversationId='') {
  const records = await rows(q(db, `SELECT scope,owner,conversation_id,config FROM v2_notification_preferences
    WHERE (scope='account' AND owner=?) OR (scope='device' AND owner=?)`,owner,device));
  const merged={enabled:true,muted:false,mute_until_ms:0,quiet_hours:null};
  const levels=[['account',owner,''],['device',device,''],...(conversationId?[['account',owner,conversationId],['device',device,conversationId]]:[])];
  for(const [scope,id,conv] of levels) {
    const r=records.find(r=>r.scope===scope&&r.owner===id&&r.conversation_id===conv);
    if(r) Object.assign(merged,JSON.parse(r.config));
  }
  return merged;
}
export async function notificationEligibility(db, job, now) {
  if(!job.message_id) return { allow:true,quietUntil:0 };
  const row=await q(db,`WITH v AS(SELECT d.subject AS owner,? AS now FROM v2_devices d WHERE d.device_id=?)
    SELECT m.conversation_id,v.owner FROM v2_messages m CROSS JOIN v WHERE m.message_id=? AND m.recipient=v.owner
    AND ${visible()} AND m.seq>COALESCE((SELECT upto_seq FROM v2_reads r WHERE r.conversation_id=m.conversation_id AND r.reader=v.owner),0)
    AND NOT EXISTS(SELECT 1 FROM v2_blocks b WHERE b.owner=v.owner AND b.blocked=m.sender)`,now,job.device_id,job.message_id).first();
  if(!row) return {allow:false,quietUntil:0};
  const config=await notificationConfig(db,row.owner,job.device_id,row.conversation_id);
  if(!config.enabled||config.muted||config.mute_until_ms>now) return {allow:false,quietUntil:0};
  return {allow:true,quietUntil:quietUntil(config.quiet_hours,now)};
}
export async function notificationRoute(req, env, db, url, auth, deps) {
  const m=url.pathname.match(/^\/chat\/v2\/(me|devices\/([^/]+))(?:\/conversations\/([^/]+))?\/notifications$/);
  if(!m) return null;
  query(url,[]); const scope=m[1]==='me'?'account':'device'; const id=scope==='account'?auth.subject:uuid(m[2]);
  if(scope==='device'&&id!==auth.device_id) fail(403,'FORBIDDEN');
  const conv=m[3]?uuid(m[3]):''; if(conv) await conversation(db,conv,auth.subject);
  const get=async()=>{
    const row=await q(db,'SELECT CAST(revision AS TEXT) AS revision,config FROM v2_notification_preferences WHERE scope=? AND owner=? AND conversation_id=?',scope,id,conv).first();
    return {revision:row?.revision??'0',overrides:row?JSON.parse(row.config):{},effective:await notificationConfig(db,auth.subject,auth.device_id,conv)};
  };
  if(req.method==='GET'){await noBody(req);return {ok:true,data:await get()};}
  const b=object(await body(req),['expected_revision','overrides']);sequence(b.expected_revision);validateNotificationConfig(b.overrides);
  await atomic(db,[sessionGuard(db,auth,deps.now()),guard(db,'COALESCE((SELECT revision FROM v2_notification_preferences WHERE scope=? AND owner=? AND conversation_id=?),0)=CAST(? AS INTEGER)',scope,id,conv,b.expected_revision),
    q(db,`INSERT INTO v2_notification_preferences(scope,owner,conversation_id,revision,config) VALUES(?,?,?,1,?)
      ON CONFLICT(scope,owner,conversation_id) DO UPDATE SET revision=revision+1,config=excluded.config`,scope,id,conv,JSON.stringify(b.overrides)),
    notifyAccount(db,auth.subject,'notification_preferences_changed',{},deps.now())]);
  return {ok:true,data:await get()};
}
