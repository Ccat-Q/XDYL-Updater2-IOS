import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,keyPair} from './helpers.js';
import {decrypt} from '../src/protocol.js';

test('stranger conversations expose current username; delayed messages carry the original sender public-key revision',async()=>{
  const f=await fixture();const a=await f.user('alice',1),b=await f.user('bob',2);
  const request=await f.message(a,b,'before rotation');const sent=await f.call('/chat/v2/messages',a.token,'POST',request);assert.equal(sent.status,200);
  const replacement=await Promise.all(['X25519','P256'].map(keyPair));
  assert.equal((await f.call(`/chat/v2/devices/${a.device_id}/keys`,a.token,'POST',{expected_revision:'1',keys:replacement.map(({privateKey,...key})=>key)})).status,200);
  const page=await f.call('/chat/v2/sync',b.token);const event=page.data.data.events.find(e=>e.type==='message');
  assert.equal(event.sender_username,'alice');assert.equal(event.envelope.sender_public_key,a.keys[0].public_key);
  assert.equal(await decrypt(b.keys[0].privateKey,event.envelope.sender_public_key,{...event,...event.envelope},event.envelope),'before rotation');
  const list=await f.call('/chat/v2/conversations',b.token);assert.equal(list.data.data.conversations[0].peer_username,'alice');
  const history=await f.call(`/chat/v2/conversations/${event.conversation_id}/messages`,b.token);assert.equal(history.data.data.messages[0].envelope.sender_public_key,a.keys[0].public_key);
  await f.call(`/chat/v2/messages/${event.message_id}`,b.token,'DELETE');
  const hidden=(await f.call('/chat/v2/sync',b.token)).data.data.events.find(e=>e.type==='message');assert.equal(hidden.envelope,undefined);
});
