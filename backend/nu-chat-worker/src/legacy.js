// Preserve the authenticated Android wire format, not its historical auth bugs.
import { fail, object, body, noBody, query, mainIdentity, username, text, publicKey,
  statement as q, rows, atomic, guard, unbase64, subject, DAY } from './common.js';
import { legacyPeer, legacySend, legacyAlgorithm } from './android.js';
import { visible } from './social.js';
export async function legacy(req, env, db, url, deps) {
  const path = url.pathname; const now = deps.now();
  if (path === '/chat/ping') {
    query(url, []); await noBody(req);
    return { ok: true, ts: now, mode: 'd1', protocol: 'legacy-d1', retention: 'operator-managed',
      limits: { page: 500 }, v2_path: '/chat/v2/capabilities' };
  }
  if (path.startsWith('/chat/key/')) {
    query(url, []); await noBody(req); let user;
    try { user = decodeURIComponent(path.slice(10)); } catch { fail(400, 'INVALID_REQUEST'); }
    username(user);
    // Modern Android sends Bearer even on key lookup. Select the matching curve
    // from the V2 primary device; never return P256 to an X25519-only client.
    let algorithm;
    if(req.headers.has('Authorization')){
      const identity=await mainIdentity(req,deps.fetch);
      const own=await q(db,'SELECT public_key FROM users WHERE username=?',identity.username).first();
      if(own)algorithm=await legacyAlgorithm(own.public_key);
    }
    const peer=await legacyPeer(db,user,algorithm);
    return { ok: true, data: { userId: user, publicKey: peer.public_key } };
  }
  const identity = await mainIdentity(req, deps.fetch);const me=identity.username;const owner=subject(identity);
  await atomic(db,[q(db,`INSERT INTO v2_accounts(subject,username) VALUES(?,?)
    ON CONFLICT(subject) DO UPDATE SET username=excluded.username`,owner,me)],'IDENTITY_CONFLICT');
  if (path === '/chat/key') {
    query(url, []); const b = object(await body(req), ['publicKey'], ['userId', 'username', 'expectedPublicKey']);
    if ((b.userId !== undefined && b.userId !== me) || (b.username !== undefined && b.username !== me)) fail(403, 'FORBIDDEN');
    let valid = false;
    for (const algorithm of ['X25519', 'P256']) {
      try { await publicKey(algorithm, b.publicKey); valid = true; break; } catch { /* Try the other legacy format. */ }
    }
    if (!valid) fail(400, 'INVALID_REQUEST');
    const binding=await q(db,'SELECT device_id FROM v2_legacy_bindings WHERE subject=? AND enabled=1',owner).first();
    if(binding){
      const bound=await legacyPeer(db,me,await legacyAlgorithm(b.publicKey));
      if(bound.public_key!==b.publicKey)fail(409,'LEGACY_ACCOUNT_ALREADY_IN_USE');
      return {ok:true,userId:me};
    }
    const old = await q(db, 'SELECT public_key FROM users WHERE username=?', me).first();
    if (old && old.public_key !== b.publicKey) {
      if (old.public_key !== b.expectedPublicKey) fail(409, 'KEY_CHANGE_REQUIRES_CONFIRMATION');
      const result = await q(db, 'UPDATE users SET public_key=?,updated_at=? WHERE username=? AND public_key=?', b.publicKey, now, me, b.expectedPublicKey).run();
      if (!result.meta.changes) fail(409, 'KEYSET_CHANGED');
    } else if (!old) {
      await q(db, `INSERT INTO users(username,public_key,updated_at) VALUES(?,?,?) ON CONFLICT(username) DO NOTHING`, me, b.publicKey, now).run();
      const row = await q(db, 'SELECT public_key FROM users WHERE username=?', me).first();
      if (row.public_key !== b.publicKey) fail(409, 'KEYSET_CHANGED');
    }
    await atomic(db,[guard(db,'EXISTS(SELECT 1 FROM users WHERE username=? AND public_key=?)',me,b.publicKey),
      q(db,'INSERT INTO v2_legacy_users(username,subject) VALUES(?,?) ON CONFLICT(username) DO UPDATE SET subject=excluded.subject',me,owner)]);
    return { ok: true, userId: me };
  }
  if (path === '/chat/send') {
    query(url, []); const b = object(await body(req), ['to', 'msgId', 'cipher', 'ts'], ['from']);
    username(b.to); text(b.msgId); text(b.cipher, 24000);
    if (b.from !== undefined && b.from !== me) fail(403, 'FORBIDDEN');
    if (!Number.isSafeInteger(b.ts) || b.ts < 0) fail(400, 'INVALID_REQUEST');
    const parts = b.cipher.split(':');
    if (parts.length !== 2 || unbase64(parts[0], 12).length !== 12 || unbase64(parts[1], 16400).length < 16) fail(400, 'INVALID_REQUEST');
    if(await q(db,'SELECT 1 FROM v2_legacy_bindings WHERE subject=? AND enabled=1',owner).first())fail(409,'LEGACY_PRIMARY_DEVICE_REQUIRED');
    return legacySend(db,env,me,{to:b.to,msgId:b.msgId,cipher:b.cipher,ts:b.ts},now);
  }
  if (path === '/chat/pull') {
    query(url, ['cursor', 'since', 'limit']); await noBody(req);
    if (url.searchParams.has('since') && url.searchParams.get('since') !== '0') fail(409, 'LEGACY_CURSOR_UNSUPPORTED');
    const cursor = url.searchParams.get('cursor') ?? '0'; const limit = url.searchParams.get('limit') ?? '200';
    if (!/^(0|[1-9][0-9]*)$/.test(cursor) || !Number.isSafeInteger(Number(cursor))
        || !/^[1-9][0-9]{0,2}$/.test(limit) || Number(limit) > 500) fail(400, 'INVALID_REQUEST');
    // Advance over filtered rows too: hiding a page must not strand the cursor.
    const list=await rows(q(db,`WITH v AS(SELECT ? AS owner,? AS now)
      SELECT old.seq,old.msg_id AS msgId,old.from_user AS 'from',old.to_user AS 'to',old.cipher,old.ts,
      CASE WHEN m.message_id IS NULL THEN 0 ELSE (${visible()}) END AS allowed
      FROM messages old CROSS JOIN v LEFT JOIN v2_legacy_link l ON l.legacy_seq=old.seq
      LEFT JOIN v2_messages m ON m.message_id=l.message_id
      WHERE(old.from_user=? OR old.to_user=?) AND old.seq>? ORDER BY old.seq LIMIT ?`,owner,now,me,me,Number(cursor),Number(limit)+1));
    const page=list.slice(0,Number(limit));
    return {ok:true,data:page.filter(r=>r.allowed).map(({allowed,...r})=>r),next_cursor:page.at(-1)?.seq??Number(cursor),has_more:list.length>Number(limit),server_time_ms:now};
  }
  if (path === '/chat/read' && req.method === 'GET') {
    query(url, ['peerId']); await noBody(req); const peer = username(url.searchParams.get('peerId'));
    const peerOwner=await q(db,'SELECT subject FROM v2_accounts WHERE username=?',peer).first();
    const mine=await q(db,`SELECT MAX(old.seq) AS upto_seq FROM messages old
      JOIN v2_legacy_link l ON l.legacy_seq=old.seq JOIN v2_messages m ON m.message_id=l.message_id
      JOIN v2_reads r ON r.conversation_id=m.conversation_id AND r.reader=?
      WHERE m.sender=? AND m.recipient=? AND m.seq<=r.upto_seq`,owner,peerOwner?.subject??'',owner).first();
    const theirs=await q(db,`SELECT MAX(old.seq) AS upto_seq FROM messages old
      JOIN v2_legacy_link l ON l.legacy_seq=old.seq JOIN v2_messages m ON m.message_id=l.message_id
      JOIN v2_reads r ON r.conversation_id=m.conversation_id AND r.reader=?
      WHERE m.sender=? AND m.recipient=? AND m.seq<=r.disclosed_seq`,peerOwner?.subject??'',owner,peerOwner?.subject??'').first();
    return { ok: true, data: { peerId: peer, own_upto: mine?.upto_seq ?? 0, peer_upto: theirs?.upto_seq ?? 0 } };
  }
  if (path === '/chat/read') {
    query(url, []); const b = object(await body(req), ['peerId', 'upto']); const peer = username(b.peerId);
    if (!Number.isSafeInteger(b.upto) || b.upto <= 0) fail(400, 'INVALID_READ_POSITION');
    if (!await q(db, 'SELECT 1 FROM messages WHERE seq=? AND from_user=? AND to_user=?', b.upto, peer, me).first()) fail(400, 'INVALID_READ_POSITION');
    const mapped=await q(db,`WITH v AS(SELECT ? AS owner,? AS now)
      SELECT m.seq,m.conversation_id FROM v2_legacy_link l CROSS JOIN v JOIN v2_messages m ON m.message_id=l.message_id
      WHERE l.legacy_seq=? AND m.recipient=? AND ${visible()}`,owner,now,b.upto,owner).first();
    if(!mapped)fail(400,'INVALID_READ_POSITION');
    const statements=[q(db, `INSERT INTO reads(reader,peer,upto_seq,updated_at) VALUES(?,?,?,?)
      ON CONFLICT(reader,peer) DO UPDATE SET upto_seq=MAX(reads.upto_seq,excluded.upto_seq),
      updated_at=CASE WHEN excluded.upto_seq>reads.upto_seq THEN excluded.updated_at ELSE reads.updated_at END`, me, peer, b.upto, now)];
    if(mapped)statements.push(q(db,`INSERT INTO v2_reads(conversation_id,reader,upto_seq,read_at,disclosed_seq)
      VALUES(?,?,?,?,CASE WHEN COALESCE((SELECT read_receipts FROM v2_preferences WHERE subject=?),1)=1 THEN ? ELSE 0 END)
      ON CONFLICT(conversation_id,reader) DO UPDATE SET upto_seq=MAX(upto_seq,excluded.upto_seq),disclosed_seq=MAX(disclosed_seq,excluded.disclosed_seq),
      read_at=CASE WHEN excluded.upto_seq>upto_seq THEN excluded.read_at ELSE read_at END`,mapped.conversation_id,owner,mapped.seq,now,owner,mapped.seq),
      q(db,`INSERT INTO v2_events(device_id,dedup,type,payload,expires_at)
        SELECT d.device_id,'read:'||r.conversation_id||':'||r.reader||':'||r.upto_seq,'read',
        json_object('type','read','conversation_id',r.conversation_id,'reader_subject',r.reader,'up_to_conversation_seq',CAST(r.upto_seq AS TEXT),'read_at_ms',r.read_at),?
        FROM v2_reads r JOIN v2_conversations c ON c.conversation_id=r.conversation_id JOIN v2_devices d ON d.subject IN(c.a,c.b) AND d.active=1 AND d.revoked=0
        WHERE r.conversation_id=? AND r.reader=? AND(d.subject=r.reader OR COALESCE((SELECT read_receipts FROM v2_preferences WHERE subject=r.reader),1)=1)
        ON CONFLICT(device_id,dedup) DO NOTHING`,now+30*DAY,mapped.conversation_id,owner));
    await atomic(db,statements);
    return { ok: true };
  }
  fail(404, 'NOT_FOUND');
}
