import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './helpers.js';
import { DAY } from '../src/common.js';
import { drainBark } from '../src/bark.js';
import { quietUntil } from '../src/notifications.js';

const good=r=>{assert.equal(r.status,200,JSON.stringify(r.data));return r.data.data;};
async function send(f,a,b){return good(await f.call('/chat/v2/messages',a.token,'POST',await f.message(a,b)));}
async function sync(f,u){return good(await f.call('/chat/v2/sync',u.token));}
async function read(f,u,m){const page=await sync(f,u);good(await f.call('/chat/v2/sync/ack',u.token,'POST',{cursor:page.next_cursor}));return f.call(`/chat/v2/conversations/${m.conversation_id}/read`,u.token,'POST',{up_to_conversation_seq:m.conversation_seq});}

test('receive policies and one-way blocks apply to sends, unblock restores access',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'0',receive_policy:'existing'}));
  assert.equal((await f.call('/chat/v2/messages',a.token,'POST',await f.message(a,b))).status,409);
  await send(f,b,a);await send(f,a,b);
  good(await f.call(`/chat/v2/blocks/${a.subject}`,b.token,'PUT',{}));
  assert.equal((await f.call('/chat/v2/messages',a.token,'POST',await f.message(a,b))).status,409);
  await send(f,b,a); // Blocker may still send.
  assert.equal(good(await f.call('/chat/v2/blocks',b.token)).blocked[0].subject,a.subject);
  good(await f.call(`/chat/v2/blocks/${a.subject}`,b.token,'DELETE'));await send(f,a,b);
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'1',receive_policy:'none'}));
  assert.equal((await f.call('/chat/v2/messages',a.token,'POST',await f.message(a,b))).status,409);
  assert.equal((await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'0'})).status,409);
});

test('private reads clear own unread, do not disclose to peer; other public reads remain visible',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'0',read_receipts:false}));
  const m=await send(f,a,b);assert.equal(good(await f.call('/chat/v2/conversations',b.token)).unread_total,1);
  good(await read(f,b,m));assert.equal(good(await f.call('/chat/v2/conversations',b.token)).unread_total,0);
  assert.equal((await sync(f,a)).events.filter(e=>e.type==='read'&&e.reader_subject===b.subject).length,0);
  assert.equal((await sync(f,b)).events.filter(e=>e.type==='read').length,1);
  const back=await send(f,b,a);good(await read(f,a,back));
  assert.equal((await sync(f,b)).events.filter(e=>e.type==='read'&&e.reader_subject===a.subject).length,1);
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'1',read_receipts:true}));
  assert.equal((await sync(f,a)).events.filter(e=>e.type==='read'&&e.reader_subject===b.subject).length,0);
});

test('conversation metadata, archive wake, own-device history gap, pagination and CAS',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2),c=await f.user('carol',3);
  const m=await send(f,a,b);await send(f,a,c);
  good(await f.call(`/chat/v2/conversations/${m.conversation_id}/state`,b.token,'PATCH',{expected_revision:'0',pinned:true,archived:true}));
  assert.equal(good(await f.call('/chat/v2/conversations',b.token)).conversations.length,0);
  assert.equal(good(await f.call('/chat/v2/conversations?archived=true',b.token)).conversations[0].pinned,true);
  await send(f,a,b);
  const list=good(await f.call('/chat/v2/conversations',b.token));assert.equal(list.conversations[0].archived,false);
  const b2=await f.user('bob',2);const gaps=good(await f.call('/chat/v2/conversations',b2.token));
  assert.equal(gaps.conversations[0].history_gap,true);assert.equal(gaps.conversations[0].unread_available,0);assert.equal(gaps.unread_total,2);
  const first=good(await f.call('/chat/v2/conversations?limit=1',a.token));assert.equal(first.has_more,true);
  const second=good(await f.call(`/chat/v2/conversations?limit=1&cursor=${encodeURIComponent(first.next_cursor)}`,a.token));
  assert.notEqual(first.conversations[0].conversation_id,second.conversations[0].conversation_id);
  assert.equal((await f.call(`/chat/v2/conversations/${m.conversation_id}/state`,b.token,'PATCH',{expected_revision:'0',pinned:false})).status,409);
});

test('hide, monotonic clear, recall and restore filters respect ownership without unread resurrection',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2),other=await f.user('carol',3);
  const m=await send(f,a,b),n=await send(f,a,b);
  assert.equal((await f.call(`/chat/v2/messages/${m.message_id}`,other.token,'DELETE')).status,403);
  good(await f.call(`/chat/v2/messages/${m.message_id}`,b.token,'DELETE'));
  let events=(await sync(f,b)).events;assert.equal(events.find(e=>e.message_id===m.message_id&&e.type==='message').envelope,undefined);
  const page=await sync(f,b);good(await f.call('/chat/v2/sync/ack',b.token,'POST',{cursor:page.next_cursor}));
  assert.equal((await f.call(`/chat/v2/conversations/${m.conversation_id}/read`,b.token,'POST',{up_to_conversation_seq:m.conversation_seq})).status,400);
  assert.equal(f.db.raw.prepare('SELECT 1 FROM v2_deliveries WHERE message_id=?').get(m.message_id),undefined);
  assert.equal(good(await f.call('/chat/v2/conversations',b.token)).unread_total,1);
  assert.equal(good(await f.call(`/chat/v2/conversations/${m.conversation_id}/messages`,a.token)).messages.length,2);
  good(await f.call(`/chat/v2/conversations/${m.conversation_id}/clear`,b.token,'POST',{expected_revision:'0',through_seq:n.conversation_seq}));
  assert.equal(good(await f.call('/chat/v2/conversations',b.token)).unread_total,0);
  const filter=good(await f.call('/chat/v2/history/filters?limit=1',b.token));assert.equal(filter.has_more,true);
  good(await f.call(`/chat/v2/messages/${n.message_id}/recall`,a.token,'POST',{}));
  assert.equal((await f.call(`/chat/v2/history/filters?cursor=${encodeURIComponent(filter.next_cursor)}`,b.token)).status,409);
  assert.equal(good(await f.call(`/chat/v2/conversations/${m.conversation_id}/messages`,a.token)).messages.length,1);
  const recent=await send(f,a,b);assert.equal(good(await f.call('/chat/v2/conversations',b.token)).unread_total,1);
  f.tick(600001);assert.equal((await f.call(`/chat/v2/messages/${recent.message_id}/recall`,a.token,'POST',{})).status,409);
  assert.equal((await f.call(`/chat/v2/messages/${recent.message_id}/recall`,b.token,'POST',{})).status,403);
});

test('retention only shortens own copies; increasing cannot resurrect and other account survives',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);const m=await send(f,a,b);
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'0',retention_days:1}));
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'1',retention_days:30}));
  f.tick(DAY+1);const a2=await f.user('alice',1),b2=await f.user('bob',2);
  assert.equal(good(await f.call('/chat/v2/conversations',b2.token)).unread_total,0);
  assert.equal(good(await f.call(`/chat/v2/conversations/${m.conversation_id}/messages`,a2.token)).history_scope,'current_device_envelopes');
  assert.equal(f.db.raw.prepare('SELECT expires_at FROM v2_copies WHERE owner=?').get(b.subject).expires_at,m.accepted_at_ms+DAY);
  assert.ok(f.db.raw.prepare('SELECT expires_at FROM v2_copies WHERE owner=?').get(a.subject).expires_at>f.now());
});

test('notification inheritance, CAS, Bark masked binding and toggle preserves encrypted secret',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);const m=await send(f,a,b);
  const dev=`/chat/v2/devices/${b.device_id}`;
  good(await f.call('/chat/v2/me/notifications',b.token,'PATCH',{expected_revision:'0',overrides:{enabled:false,muted:true}}));
  good(await f.call(`${dev}/notifications`,b.token,'PATCH',{expected_revision:'0',overrides:{enabled:true}}));
  good(await f.call(`/chat/v2/me/conversations/${m.conversation_id}/notifications`,b.token,'PATCH',{expected_revision:'0',overrides:{muted:false}}));
  assert.equal(good(await f.call(`${dev}/conversations/${m.conversation_id}/notifications`,b.token)).effective.enabled,true);
  assert.equal(good(await f.call(`${dev}/conversations/${m.conversation_id}/notifications`,b.token)).effective.muted,false);
  assert.equal((await f.call(`${dev}/notifications`,b.token,'PATCH',{expected_revision:'0',overrides:{}})).status,409);
  good(await f.call(`${dev}/bark`,b.token,'PUT',{enabled:true,device_key:'secret-1234'}));
  const masked=good(await f.call(`${dev}/bark`,b.token));assert.equal(masked.device_key_masked,'••••1234');assert.ok(!JSON.stringify(masked).includes('secret'));
  good(await f.call(`${dev}/bark`,b.token,'PUT',{enabled:false,expected_revision:'1'}));
  good(await f.call(`${dev}/bark`,b.token,'PUT',{enabled:true,expected_revision:'2'}));
  good(await f.call(`${dev}/bark/test`,b.token,'POST',{}));await drainBark(f.env,f.db,f.deps);assert.equal(f.bark[0].device_key,'secret-1234');
});

test('IANA quiet hours handle crossing midnight, weekday start and DST',()=>{
  const hours={timezone:'Asia/Shanghai',start:'23:00',end:'07:00',weekdays:[1]};
  assert.equal(quietUntil(hours,Date.parse('2026-10-19T16:00:00Z')),Date.parse('2026-10-19T23:00:00Z'));
  assert.equal(quietUntil(hours,Date.parse('2026-10-20T16:00:00Z')),0);
  const dst={timezone:'America/New_York',start:'00:00',end:'03:00',weekdays:[7]};
  assert.equal(quietUntil(dst,Date.parse('2026-11-01T04:30:00Z')),Date.parse('2026-11-01T08:00:00Z'));
});

test('quiet end sends one generic summary, ACK alone does not hide unread; read/deleted jobs are excluded',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);
  const d=new Date(f.now());const start=`${String(d.getUTCHours()).padStart(2,'0')}:00`,end=`${String(d.getUTCHours()+1).padStart(2,'0')}:00`;
  good(await f.call('/chat/v2/me/notifications',b.token,'PATCH',{expected_revision:'0',overrides:{quiet_hours:{timezone:'UTC',start,end,weekdays:[1,2,3,4,5,6,7]}}}));
  good(await f.call(`/chat/v2/devices/${b.device_id}/bark`,b.token,'PUT',{enabled:true,device_key:'test-key'}));
  const m=await send(f,a,b);await send(f,a,b);await send(f,a,b);
  await drainBark(f.env,f.db,f.deps);assert.equal(f.bark.length,0);
  const page=await sync(f,b);good(await f.call('/chat/v2/sync/ack',b.token,'POST',{cursor:page.next_cursor}));
  good(await f.call(`/chat/v2/messages/${m.message_id}`,b.token,'DELETE'));
  f.tick(3600000);await drainBark(f.env,f.db,f.deps);
  assert.equal(f.bark.length,1);assert.equal(f.bark[0].body,'你有未读私聊，请打开应用查看');
  assert.equal(f.db.raw.prepare("SELECT COUNT(*) AS n FROM v2_outbox WHERE state='accepted'").get().n,1);
});

test('private read cancels pending reminders without disclosing to peer; schema/config gaps fail closed',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);
  good(await f.call(`/chat/v2/devices/${b.device_id}/bark`,b.token,'PUT',{enabled:true,device_key:'test-key'}));
  good(await f.call('/chat/v2/me/preferences',b.token,'PATCH',{expected_revision:'0',read_receipts:false}));
  const m=await send(f,a,b);good(await read(f,b,m));await drainBark(f.env,f.db,f.deps);assert.equal(f.bark.length,0);
  f.db.raw.exec('DELETE FROM v2_schema');assert.equal((await f.call('/chat/v2/capabilities')).status,503);
});
