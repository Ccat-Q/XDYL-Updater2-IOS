ALTER TABLE v2_messages ADD COLUMN recalled_at INTEGER;
ALTER TABLE v2_reads ADD COLUMN disclosed_seq INTEGER NOT NULL DEFAULT 0;
UPDATE v2_reads SET disclosed_seq=upto_seq;
CREATE TABLE v2_preferences (
  subject TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0,
  receive_policy TEXT NOT NULL DEFAULT 'everyone' CHECK(receive_policy IN ('everyone','existing','none')),
  read_receipts INTEGER NOT NULL DEFAULT 1, retention_days INTEGER NOT NULL DEFAULT 30 CHECK(retention_days IN(1,7,30))
);
CREATE TABLE v2_conversation_state (
  owner TEXT NOT NULL, conversation_id TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
  archived_seq INTEGER NOT NULL DEFAULT 0, clear_seq INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(owner,conversation_id)
);
CREATE TABLE v2_hidden (
  owner TEXT NOT NULL, message_id TEXT NOT NULL, hidden_at INTEGER NOT NULL,
  PRIMARY KEY(owner,message_id)
);
CREATE TABLE v2_copies (
  owner TEXT NOT NULL, message_id TEXT NOT NULL, expires_at INTEGER NOT NULL,
  PRIMARY KEY(owner,message_id)
);
CREATE TABLE v2_filter_clock(owner TEXT PRIMARY KEY,revision INTEGER NOT NULL DEFAULT 0);
CREATE INDEX v2_messages_recipient ON v2_messages(recipient,seq);
CREATE INDEX v2_messages_sender ON v2_messages(sender,seq);
INSERT INTO v2_copies SELECT sender,message_id,expires_at FROM v2_messages;
INSERT OR IGNORE INTO v2_copies SELECT recipient,message_id,expires_at FROM v2_messages;
CREATE TABLE v2_blocks (
  owner TEXT NOT NULL, blocked TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY(owner,blocked), CHECK(owner<>blocked)
);
CREATE TABLE v2_notification_preferences (
  scope TEXT NOT NULL CHECK(scope IN('account','device')),
  owner TEXT NOT NULL, conversation_id TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL DEFAULT 0, config TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY(scope,owner,conversation_id)
);
ALTER TABLE v2_bark ADD COLUMN revision INTEGER NOT NULL DEFAULT 1;
ALTER TABLE v2_outbox ADD COLUMN quiet_summary INTEGER NOT NULL DEFAULT 0;
ALTER TABLE v2_outbox ADD COLUMN quiet_until INTEGER NOT NULL DEFAULT 0;
CREATE TABLE v2_notification_summaries (
  device_id TEXT NOT NULL, window_end INTEGER NOT NULL,
  notification_id TEXT NOT NULL, PRIMARY KEY(device_id,window_end)
);
CREATE TABLE v2_recovery_packs (
  pack_id TEXT PRIMARY KEY, owner TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN('backup','transfer')),
  source_device TEXT, target_device TEXT, creator_device TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('awaiting_approval','uploading','ready','completed','cancelled','expired','deleting')),
  revision INTEGER NOT NULL DEFAULT 1, expected_bytes INTEGER NOT NULL CHECK(expected_bytes>0),
  chunk_count INTEGER NOT NULL, manifest TEXT,
  target_public_key TEXT, source_public_key TEXT, approval_proof TEXT,
  recovery_key_id TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  approval_expires_at INTEGER, completed_at INTEGER, creation_hash TEXT NOT NULL,
  gc_done INTEGER NOT NULL DEFAULT 0, delete_reason TEXT NOT NULL DEFAULT 'cancelled'
);
CREATE INDEX v2_packs_owner ON v2_recovery_packs(owner,created_at,pack_id);
CREATE TABLE v2_recovery_chunks (
  pack_id TEXT NOT NULL REFERENCES v2_recovery_packs(pack_id),
  chunk_index INTEGER NOT NULL CHECK(chunk_index>=0), bytes INTEGER NOT NULL,
  digest TEXT NOT NULL, object_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN('writing','ready')),
  PRIMARY KEY(pack_id,chunk_index)
);
CREATE TABLE v2_transfer_candidates (
  pack_id TEXT NOT NULL, device_id TEXT NOT NULL, key_revision INTEGER NOT NULL,
  PRIMARY KEY(pack_id,device_id)
);
CREATE TABLE v2_blob_gc_state(id INTEGER PRIMARY KEY CHECK(id=1),cursor TEXT);
INSERT INTO v2_blob_gc_state VALUES(1,NULL);
