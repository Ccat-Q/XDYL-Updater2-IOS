import { fail, object, body, noBody, query, text, uuid, sequence, statement as q, rows, guard, atomic, DAY } from './common.js';
import { sessionGuard, conversation, messagePayload } from './store.js';
import { signOpaque, readOpaque } from './cursor.js';

// SQL identifiers here are internal constants, never caller-provided strings.
export const visible = (m = 'm', viewer = 'v') => `${m}.recalled_at IS NULL
  AND EXISTS(SELECT 1 FROM v2_copies cp WHERE cp.owner=${viewer}.owner AND cp.message_id=${m}.message_id AND cp.expires_at>${viewer}.now)
  AND NOT EXISTS(SELECT 1 FROM v2_hidden h WHERE h.owner=${viewer}.owner AND h.message_id=${m}.message_id)
  AND ${m}.seq>COALESCE((SELECT cs.clear_seq FROM v2_conversation_state cs WHERE cs.owner=${viewer}.owner AND cs.conversation_id=${m}.conversation_id),0)`;

export function notifyAccount(db, owner, type, payload, now, id = crypto.randomUUID()) {
  return q(db, `INSERT INTO v2_events(device_id,dedup,type,payload,expires_at)
    SELECT device_id,?,?,?,? FROM v2_devices WHERE subject=? AND active=1 AND revoked=0
    ON CONFLICT(device_id,dedup) DO NOTHING`, `${type}:${id}`, type, JSON.stringify({ type, ...payload }), now + 30 * DAY, owner);
}
export const filterTick=(db,owner)=>q(db,`INSERT INTO v2_filter_clock(owner,revision) VALUES(?,1)
  ON CONFLICT(owner) DO UPDATE SET revision=revision+1`,owner);
export function deliveryGuard(db, sender, recipient) {
  return guard(db, `NOT EXISTS(SELECT 1 FROM v2_blocks WHERE owner=? AND blocked=?)
    AND (COALESCE((SELECT receive_policy FROM v2_preferences WHERE subject=?),'everyone')='everyone'
    OR (COALESCE((SELECT receive_policy FROM v2_preferences WHERE subject=?),'everyone')='existing'
      AND EXISTS(SELECT 1 FROM v2_messages WHERE sender=? AND recipient=?)))`, recipient, sender, recipient, recipient, recipient, sender);
}
export async function preferences(db, owner) {
  const p = await q(db, `SELECT CAST(revision AS TEXT) AS revision,receive_policy,read_receipts,retention_days FROM v2_preferences WHERE subject=?`, owner).first();
  return p ? { ...p, read_receipts: !!p.read_receipts } : { revision: '0', receive_policy: 'everyone', read_receipts: true, retention_days: 30 };
}
async function state(db, owner, id) {
  const s = await q(db, `SELECT CAST(revision AS TEXT) AS revision,pinned,
    CASE WHEN archived_seq>=COALESCE((SELECT MAX(seq) FROM v2_messages WHERE conversation_id=v2_conversation_state.conversation_id),0) THEN archived ELSE 0 END AS archived,
    CAST(archived_seq AS TEXT) AS archived_seq,
    CAST(clear_seq AS TEXT) AS clear_seq FROM v2_conversation_state WHERE owner=? AND conversation_id=?`, owner, id).first();
  return s ? { ...s, pinned: !!s.pinned, archived: !!s.archived } : { revision: '0', pinned: false, archived: false, archived_seq: '0', clear_seq: '0' };
}
export async function socialRoute(req, env, db, url, auth, deps) {
  const path = url.pathname; const method = req.method; const now = deps.now(); const owner = auth.subject;
  const sg = () => sessionGuard(db, auth, now); const ok = data => data === undefined ? { ok: true } : { ok: true, data };
  if (path === '/chat/v2/me/preferences') {
    query(url, []);
    if (method === 'GET') { await noBody(req); return ok(await preferences(db, owner)); }
    const b = object(await body(req), ['expected_revision'], ['receive_policy', 'read_receipts', 'retention_days']); sequence(b.expected_revision);
    if (b.receive_policy !== undefined && !['everyone', 'existing', 'none'].includes(b.receive_policy)) fail(400, 'INVALID_REQUEST');
    if (b.read_receipts !== undefined && typeof b.read_receipts !== 'boolean') fail(400, 'INVALID_REQUEST');
    if (b.retention_days !== undefined && ![1, 7, 30].includes(b.retention_days)) fail(400, 'INVALID_REQUEST');
    const old = await preferences(db, owner); const next = { ...old, ...b };
    await atomic(db, [sg(), guard(db, `COALESCE((SELECT revision FROM v2_preferences WHERE subject=?),0)=CAST(? AS INTEGER)`, owner, b.expected_revision),
      q(db, `INSERT INTO v2_preferences(subject,revision,receive_policy,read_receipts,retention_days) VALUES(?,1,?,?,?)
        ON CONFLICT(subject) DO UPDATE SET revision=revision+1,receive_policy=excluded.receive_policy,read_receipts=excluded.read_receipts,retention_days=excluded.retention_days`,
      owner, next.receive_policy, next.read_receipts ? 1 : 0, next.retention_days),
      q(db, `UPDATE v2_copies SET expires_at=MIN(expires_at,(SELECT accepted_at FROM v2_messages m WHERE m.message_id=v2_copies.message_id)+?) WHERE owner=?`, next.retention_days * DAY, owner),
      q(db, `UPDATE v2_events SET expires_at=MIN(expires_at,(SELECT cp.expires_at FROM v2_copies cp WHERE cp.owner=? AND cp.message_id=v2_events.message_id))
        WHERE type='message' AND device_id IN(SELECT device_id FROM v2_devices WHERE subject=?)`, owner, owner),
      notifyAccount(db, owner, 'preferences_changed', {}, now)]);
    return ok(await preferences(db, owner));
  }
  if (path === '/chat/v2/blocks' && method === 'GET') {
    query(url, []); await noBody(req);
    return ok({ blocked: await rows(q(db, 'SELECT blocked AS subject,created_at AS blocked_at_ms FROM v2_blocks WHERE owner=? ORDER BY created_at,blocked', owner)) });
  }
  let match = path.match(/^\/chat\/v2\/blocks\/([^/]+)$/);
  if (match) {
    query(url, []); let peer; try { peer = decodeURIComponent(match[1]); } catch { fail(400, 'INVALID_REQUEST'); }
    text(peer); if (peer === owner) fail(400, 'INVALID_REQUEST');
    if (!await q(db, 'SELECT 1 FROM v2_accounts WHERE subject=?', peer).first()) fail(404, 'USER_NOT_FOUND');
    if (method === 'PUT') {
      object(await body(req), []);
      await atomic(db, [sg(), q(db, 'INSERT INTO v2_blocks(owner,blocked,created_at) VALUES(?,?,?) ON CONFLICT(owner,blocked) DO NOTHING', owner, peer, now),
        q(db, `UPDATE v2_outbox SET state='cancelled',lease_token=NULL,lease_until=0 WHERE state IN('queued','leased') AND device_id IN
          (SELECT device_id FROM v2_devices WHERE subject=?) AND message_id IN(SELECT message_id FROM v2_messages WHERE sender=? AND recipient=?)`, owner, peer, owner),
        notifyAccount(db, owner, 'blocks_changed', {}, now)]);
    } else {
      await noBody(req); await atomic(db, [sg(), q(db, 'DELETE FROM v2_blocks WHERE owner=? AND blocked=?', owner, peer), notifyAccount(db, owner, 'blocks_changed', {}, now)]);
    }
    return ok();
  }
  if (path === '/chat/v2/conversations' && method === 'GET') {
    query(url, ['cursor', 'limit', 'archived']); await noBody(req);
    const limit = Number(url.searchParams.get('limit') ?? '50');
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail(400, 'INVALID_REQUEST');
    const archived = url.searchParams.get('archived') ?? 'false'; if (!['true', 'false', 'all'].includes(archived)) fail(400, 'INVALID_REQUEST');
    let cursor = { pin: 2, last: '9223372036854775807', id: '' };
    if (url.searchParams.has('cursor')) {
      cursor = await readOpaque(env, url.searchParams.get('cursor'));
      if (cursor.scope !== `conversations:${archived}` || cursor.owner !== owner || cursor.device !== auth.device_id) fail(403, 'FORBIDDEN');
      sequence(cursor.last); if (![0, 1, 2].includes(cursor.pin) || typeof cursor.id !== 'string') fail(400, 'INVALID_CURSOR');
    }
    const result = await rows(q(db, `WITH v AS(SELECT ? AS owner,? AS device,? AS now), items AS(
      SELECT c.conversation_id,CASE WHEN c.a=v.owner THEN c.b ELSE c.a END AS peer_subject,
      (SELECT username FROM v2_accounts WHERE subject=CASE WHEN c.a=v.owner THEN c.b ELSE c.a END) AS peer_username,
      COALESCE(cs.pinned,0) AS pinned,CASE WHEN cs.archived=1 AND cs.archived_seq>=COALESCE((SELECT MAX(seq) FROM v2_messages WHERE conversation_id=c.conversation_id),0) THEN 1 ELSE 0 END AS archived,
      CAST(COALESCE((SELECT MAX(seq) FROM v2_messages WHERE conversation_id=c.conversation_id),0) AS TEXT) AS last_seq,
      (SELECT message_id FROM v2_messages m WHERE m.conversation_id=c.conversation_id AND ${visible()} ORDER BY m.seq DESC LIMIT 1) AS last_visible_message_id,
      (SELECT COUNT(*) FROM v2_messages m WHERE m.conversation_id=c.conversation_id AND m.recipient=v.owner AND ${visible()}
        AND m.seq>COALESCE((SELECT upto_seq FROM v2_reads WHERE conversation_id=c.conversation_id AND reader=v.owner),0)) AS unread_total,
      (SELECT COUNT(*) FROM v2_messages m WHERE m.conversation_id=c.conversation_id AND m.recipient=v.owner AND ${visible()}
        AND m.seq>COALESCE((SELECT upto_seq FROM v2_reads WHERE conversation_id=c.conversation_id AND reader=v.owner),0)
        AND EXISTS(SELECT 1 FROM v2_events e WHERE e.device_id=v.device AND e.message_id=m.message_id AND e.type='message' AND e.expires_at>v.now)) AS unread_available,
      EXISTS(SELECT 1 FROM v2_messages m WHERE m.conversation_id=c.conversation_id AND ${visible()}
        AND NOT EXISTS(SELECT 1 FROM v2_events e WHERE e.device_id=v.device AND e.message_id=m.message_id AND e.type='message' AND e.expires_at>v.now)) AS history_gap,
      CAST(COALESCE(cs.revision,0) AS TEXT) AS revision
      FROM v2_conversations c CROSS JOIN v LEFT JOIN v2_conversation_state cs ON cs.owner=v.owner AND cs.conversation_id=c.conversation_id WHERE c.a=v.owner OR c.b=v.owner)
      SELECT * FROM items WHERE (?='all' OR archived=?) AND (pinned<? OR (pinned=? AND (CAST(last_seq AS INTEGER)<? OR (CAST(last_seq AS INTEGER)=? AND conversation_id>?))))
      ORDER BY pinned DESC,CAST(last_seq AS INTEGER) DESC,conversation_id LIMIT ?`,
    owner, auth.device_id, now, archived, archived === 'true' ? 1 : 0, cursor.pin, cursor.pin, cursor.last, cursor.last, cursor.id, limit + 1));
    const page = result.slice(0, limit); const last = page.at(-1);
    const summary = await q(db, `WITH v AS(SELECT ? AS owner,? AS now) SELECT COUNT(*) AS unread_total FROM v2_messages m CROSS JOIN v
      WHERE m.recipient=v.owner AND ${visible()} AND m.seq>COALESCE((SELECT upto_seq FROM v2_reads r WHERE r.conversation_id=m.conversation_id AND r.reader=v.owner),0)`, owner, now).first();
    return ok({ conversations: page.map(r => ({ ...r, pinned: !!r.pinned, archived: !!r.archived, history_gap: !!r.history_gap })),
      unread_total: summary.unread_total, has_more: result.length > limit,
      next_cursor: last ? await signOpaque(env, { scope: `conversations:${archived}`, owner, device: auth.device_id, pin: last.pinned, last: last.last_seq, id: last.conversation_id }) : null });
  }
  match = path.match(/^\/chat\/v2\/conversations\/([^/]+)\/(state|clear|messages)$/);
  if (match) {
    const id = uuid(match[1]); await conversation(db, id, owner); const action = match[2];
    if (action === 'messages') {
      query(url, ['before', 'limit']); await noBody(req); const before = sequence(url.searchParams.get('before') ?? '9223372036854775807');
      const limit = Number(url.searchParams.get('limit') ?? '100'); if (!Number.isInteger(limit) || limit < 1 || limit > 200) fail(400, 'INVALID_REQUEST');
      const list = await rows(q(db, `WITH v AS(SELECT ? AS owner,? AS now) SELECT CAST(m.seq AS TEXT) AS seq,${messagePayload()} AS payload FROM v2_messages m CROSS JOIN v
        JOIN v2_events e ON e.message_id=m.message_id AND e.type='message' AND e.device_id=? WHERE m.conversation_id=? AND m.seq<? AND ${visible()} AND e.expires_at>v.now
        ORDER BY m.seq DESC LIMIT ?`, owner, now, auth.device_id, id, before, limit + 1));
      const page = list.slice(0, limit);
      return ok({ messages: page.map(r => JSON.parse(r.payload)), has_more: list.length > limit, next_before: page.at(-1)?.seq ?? null,
        history_scope: 'current_device_envelopes' });
    }
    query(url, []); const current = await state(db, owner, id);
    if (method === 'GET') { await noBody(req); return ok(current); }
    const b = object(await body(req), ['expected_revision'], action === 'clear' ? ['through_seq'] : ['pinned', 'archived']); sequence(b.expected_revision);
    const next = { ...current };
    if (action === 'state') for (const key of ['pinned', 'archived']) {
      if (b[key] !== undefined && typeof b[key] !== 'boolean') fail(400, 'INVALID_REQUEST');
      if (b[key] !== undefined) next[key] = b[key];
    }
    const latest = await q(db, 'SELECT CAST(COALESCE(MAX(seq),0) AS TEXT) AS seq FROM v2_messages WHERE conversation_id=?', id).first();
    if (action === 'clear') {
      sequence(b.through_seq); if (BigInt(b.through_seq) > BigInt(latest.seq)) fail(400, 'INVALID_REQUEST');
      next.clear_seq = String(BigInt(b.through_seq) > BigInt(current.clear_seq) ? b.through_seq : current.clear_seq);
    }
    next.archived_seq = next.archived ? latest.seq : '0';
    await atomic(db, [sg(), guard(db, 'COALESCE((SELECT revision FROM v2_conversation_state WHERE owner=? AND conversation_id=?),0)=CAST(? AS INTEGER)', owner, id, b.expected_revision),
      q(db, `INSERT INTO v2_conversation_state(owner,conversation_id,revision,pinned,archived,archived_seq,clear_seq) VALUES(?,?,1,?,?,?,?)
        ON CONFLICT(owner,conversation_id) DO UPDATE SET revision=revision+1,pinned=excluded.pinned,archived=excluded.archived,archived_seq=excluded.archived_seq,clear_seq=MAX(v2_conversation_state.clear_seq,excluded.clear_seq)`,
      owner, id, next.pinned ? 1 : 0, next.archived ? 1 : 0, next.archived_seq, next.clear_seq),
      ...(action==='clear'?[filterTick(db,owner)]:[]),
      notifyAccount(db, owner, action === 'clear' ? 'history_cleared' : 'conversation_state_changed', { conversation_id: id, through_seq: next.clear_seq }, now)]);
    return ok(await state(db, owner, id));
  }
  match = path.match(/^\/chat\/v2\/messages\/([^/]+)(\/recall)?$/);
  if (match) {
    query(url, []); const id = uuid(match[1]);
    const m = await q(db, 'SELECT * FROM v2_messages WHERE message_id=?', id).first();
    if (!m) fail(404, 'MESSAGE_NOT_FOUND');
    if (m.sender !== owner && m.recipient !== owner) fail(403, 'FORBIDDEN');
    if (!match[2]) {
      await noBody(req);
      await atomic(db, [sg(), q(db, 'INSERT INTO v2_hidden(owner,message_id,hidden_at) VALUES(?,?,?) ON CONFLICT(owner,message_id) DO NOTHING', owner, id, now),
        filterTick(db,owner),notifyAccount(db, owner, 'message_hidden', { message_id: id }, now)]); return ok();
    }
    object(await body(req), []); if (m.sender !== owner) fail(403, 'FORBIDDEN');
    if (m.recalled_at) return ok({ recalled_at_ms: m.recalled_at });
    if (now - m.accepted_at > 600000) fail(409, 'RECALL_WINDOW_EXPIRED');
    await atomic(db, [sg(), guard(db, 'EXISTS(SELECT 1 FROM v2_messages WHERE message_id=? AND accepted_at>=?)', id, now - 600000),
      q(db, 'UPDATE v2_messages SET recalled_at=COALESCE(recalled_at,?) WHERE message_id=?', now, id),
      q(db, `UPDATE v2_events SET payload=json_set(json_remove(payload,'$.envelope'),'$.unavailable','recalled') WHERE message_id=? AND type='message'`, id),
      q(db, "UPDATE v2_outbox SET state='cancelled',lease_token=NULL,lease_until=0 WHERE message_id=? AND state IN('queued','leased')", id),
      filterTick(db,m.sender),filterTick(db,m.recipient),
      notifyAccount(db, m.sender, 'message_recalled', { message_id: id }, now, id), notifyAccount(db, m.recipient, 'message_recalled', { message_id: id }, now, id)]);
    return ok({ recalled_at_ms: now });
  }
  return null;
}
