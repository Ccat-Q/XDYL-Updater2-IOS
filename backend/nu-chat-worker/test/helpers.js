import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { createWorker } from '../src/index.js';
import { base64 } from '../src/common.js';
import { encrypt } from '../src/protocol.js';

// SQL is real SQLite, not hand-matched mock responses. Separate runtime tests
// exercise the same migrations and modules in Cloudflare workerd/Miniflare.
export class SQLiteD1 {
  constructor() {
    this.raw = new DatabaseSync(':memory:'); this.raw.exec('PRAGMA foreign_keys=ON');
    for (const name of ['0001_legacy.sql', '0002_v2.sql', '0003_frontend.sql', '0004_android_interop.sql']) this.raw.exec(readFileSync(new URL(`../migrations/${name}`, import.meta.url), 'utf8'));
    this.primaryReads = 0;
  }
  withSession(mode) { if (mode !== 'first-primary') throw new Error('unexpected session'); this.primaryReads++; return this; }
  prepare(sql) {
    const db = this.raw; let args = [];
    const stmt = {
      sql,
      bind(...values) { args = values; return stmt; },
      async first() { return db.prepare(sql).get(...args) ?? null; },
      async all() { return { results: db.prepare(sql).all(...args) }; },
      async run() { const r = db.prepare(sql).run(...args); return { meta: { changes: r.changes, last_row_id: r.lastInsertRowid } }; },
      execute() {
        const prepared = db.prepare(sql);
        if (prepared.columns().length) return { results: prepared.all(...args), meta: { changes: 0 } };
        const r = prepared.run(...args); return { results: [], meta: { changes: r.changes } };
      }
    };
    return stmt;
  }
  async batch(stmts) {
    this.raw.exec('BEGIN IMMEDIATE');
    try { const result = stmts.map(s => s.execute()); this.raw.exec('COMMIT'); return result; }
    catch (e) { this.raw.exec('ROLLBACK'); throw e; }
  }
}
export class MemoryR2 {
  objects=new Map();
  async put(key,bytes){this.objects.set(key,new Uint8Array(bytes));}
  async get(key){const bytes=this.objects.get(key);return bytes?{body:bytes.slice()}:null;}
  async delete(keys){for(const k of Array.isArray(keys)?keys:[keys])this.objects.delete(k);}
  async list({prefix='',limit=1000,cursor}={}){
    const keys=[...this.objects.keys()].filter(k=>k.startsWith(prefix)&&(!cursor||k>cursor)).sort();
    const page=keys.slice(0,limit);return {objects:page.map(key=>({key})),truncated:keys.length>limit,cursor:page.at(-1)};
  }
}
export async function keyPair(algorithm) {
  const spec = algorithm === 'X25519' ? { name: 'X25519' } : { name: 'ECDH', namedCurve: 'P-256' };
  const pair = await crypto.subtle.generateKey(spec, true, ['deriveBits']);
  return { algorithm, key_id: crypto.randomUUID(), public_key: base64(await crypto.subtle.exportKey('spki', pair.publicKey)), privateKey: pair.privateKey };
}
export async function fixture(options = {}) {
  const db = new SQLiteD1(); let clock = 1792386000000;
  const identities = new Map(); const calls = []; const bark = [];
  let authResponse = null; let barkResponse = () => Response.json({ code: 200 });
  const fetcher = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init); calls.push(request);
    if (request.url === 'https://login.lanternwaves.fun/user/profile') {
      if (authResponse) return authResponse();
      const identity = identities.get(request.headers.get('Authorization')?.slice(7));
      return Response.json(identity ? { code: 200, data: identity } : { code: 401 }, { status: identity ? 200 : 401 });
    }
    if (request.url === 'https://api.day.app/push') { bark.push(await request.json()); return barkResponse(); }
    throw new Error('unexpected network destination');
  };
  const deps = { now: () => clock, fetch: fetcher, random: () => 0 };
  const worker = createWorker(deps);
  const env = { DB: db, CURSOR_SECRET: base64(new Uint8Array(32).fill(10)),
    BARK_ENABLED: 'true', BARK_ENCRYPTION_KEY: base64(new Uint8Array(32).fill(20)), ...options };
  async function call(path, token, method = 'GET', data, extra = {}) {
    const req = new Request(`https://chat.example${path}`, { method, headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(data !== undefined ? { 'Content-Type': data instanceof Uint8Array?'application/octet-stream':'application/json' } : {}),
      'CF-Connecting-IP': '203.0.113.7', ...extra
    }, body: data === undefined ? undefined : data instanceof Uint8Array?data:JSON.stringify(data) });
    const r = await worker.fetch(req, env); return { status: r.status,
      data: r.headers.get('Content-Type')?.includes('application/json')?await r.json():new Uint8Array(await r.arrayBuffer()), headers: r.headers };
  }
  async function user(name, id, activate = true) {
    const device_id = crypto.randomUUID(); const token = `${name}-${device_id}`;
    identities.set(token, { id, username: name });
    const session = await call('/chat/v2/session', token, 'POST', { device_id, device_name: name });
    if (session.status !== 200) throw new Error(JSON.stringify(session.data));
    const result = { ...session.data.data, token: session.data.data.chat_token, mainToken: token, keys: [] };
    if (activate) {
      result.keys = await Promise.all(['X25519', 'P256'].map(keyPair));
      const registration = await call(`/chat/v2/devices/${device_id}/keys`, result.token, 'POST', { expected_revision: '0',
        keys: result.keys.map(({ privateKey, ...key }) => key) });
      if (registration.status !== 200) throw new Error(JSON.stringify(registration.data));
    }
    return result;
  }
  async function message(sender, recipient, text = '你好，世界🌊', algorithm = 'X25519') {
    const a = (await call(`/chat/v2/users/${sender.username}/keys`, sender.token)).data.data;
    const b = (await call(`/chat/v2/users/${recipient.username}/keys`, sender.token)).data.data;
    const id = crypto.randomUUID(); const local = sender.keys.find(k => k.algorithm === algorithm); const envelopes = [];
    for (const account of [a, b]) for (const device of account.devices) {
      const remote = device.keys.find(k => k.algorithm === algorithm);
      const metadata = { sender_subject: sender.subject, sender_device_id: sender.device_id, recipient_subject: recipient.subject,
        client_msg_id: id, target_subject: account.subject, target_device_id: device.device_id,
        algorithm, sender_key_id: local.key_id, recipient_key_id: remote.key_id };
      const encrypted = await encrypt(local.privateKey, remote.public_key, metadata, text);
      const { sender_subject, sender_device_id, recipient_subject, client_msg_id, ...envelope } = metadata;
      envelopes.push({ ...envelope, ...encrypted });
    }
    return { client_msg_id: id, to_subject: recipient.subject, client_sent_at_ms: clock,
      sender_keyset_revision: a.keyset_revision, recipient_keyset_revision: b.keyset_revision, envelopes };
  }
  return { db, env, worker, deps, call, user, message, identities, calls, bark,
    tick(ms) { clock += ms; }, now: () => clock,
    setAuth(fn) { authResponse = fn; }, setBark(fn) { barkResponse = fn; } };
}
