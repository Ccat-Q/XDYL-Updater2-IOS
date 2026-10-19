-- V2 never treats legacy username keys as device keys; all tables are separate.
CREATE TABLE v2_accounts (
  subject TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE,
  keyset_revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE v2_devices (
  device_id TEXT PRIMARY KEY, subject TEXT NOT NULL REFERENCES v2_accounts(subject),
  name TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0, key_revision INTEGER NOT NULL DEFAULT 0,
  ack_seq INTEGER NOT NULL DEFAULT 0, floor_seq INTEGER NOT NULL DEFAULT 0,
  max_issued_seq INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
);
CREATE INDEX v2_devices_owner ON v2_devices(subject, revoked);
CREATE TABLE v2_sessions (
  token_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES v2_devices(device_id),
  expires_at INTEGER NOT NULL
);
CREATE INDEX v2_sessions_expiry ON v2_sessions(expires_at);
CREATE TABLE v2_keys (
  key_id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES v2_devices(device_id),
  algorithm TEXT NOT NULL CHECK(algorithm IN ('X25519','P256')),
  public_key TEXT NOT NULL, revision INTEGER NOT NULL,
  UNIQUE(device_id, revision, algorithm)
);
CREATE TABLE v2_key_operations (
  device_id TEXT NOT NULL, expected_revision INTEGER NOT NULL,
  request_hash TEXT NOT NULL, result TEXT NOT NULL,
  PRIMARY KEY(device_id, expected_revision)
);
CREATE TABLE v2_conversations (
  conversation_id TEXT PRIMARY KEY, a TEXT NOT NULL, b TEXT NOT NULL,
  UNIQUE(a,b), CHECK(a < b)
);
CREATE TABLE v2_messages (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL UNIQUE,
  client_msg_id TEXT NOT NULL, sender TEXT NOT NULL,
  sender_device TEXT NOT NULL, recipient TEXT NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES v2_conversations(conversation_id),
  request_hash TEXT NOT NULL, accepted_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE(sender, sender_device, client_msg_id)
);
CREATE INDEX v2_messages_expiry ON v2_messages(expires_at);
CREATE INDEX v2_messages_conversation ON v2_messages(conversation_id, seq);
CREATE TABLE v2_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL,
  dedup TEXT NOT NULL, type TEXT NOT NULL, message_id TEXT,
  payload TEXT NOT NULL, expires_at INTEGER NOT NULL,
  UNIQUE(device_id, dedup)
);
CREATE INDEX v2_events_sync ON v2_events(device_id, seq);
CREATE INDEX v2_events_expiry ON v2_events(expires_at);
CREATE TABLE v2_deliveries (
  message_id TEXT NOT NULL, device_id TEXT NOT NULL,
  received_at INTEGER NOT NULL, PRIMARY KEY(message_id, device_id)
);
CREATE TABLE v2_reads (
  conversation_id TEXT NOT NULL, reader TEXT NOT NULL,
  upto_seq INTEGER NOT NULL, read_at INTEGER NOT NULL,
  PRIMARY KEY(conversation_id, reader)
);
CREATE TABLE v2_bark (
  device_id TEXT PRIMARY KEY, server_url TEXT NOT NULL,
  encrypted_key TEXT NOT NULL, version TEXT NOT NULL,
  enabled INTEGER NOT NULL, last_attempt INTEGER,
  last_result TEXT NOT NULL DEFAULT 'none', last_error TEXT
);
CREATE TABLE v2_outbox (
  notification_id TEXT PRIMARY KEY, device_id TEXT NOT NULL,
  message_id TEXT, binding_version TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL,
  lease_until INTEGER NOT NULL DEFAULT 0, lease_token TEXT,
  state TEXT NOT NULL DEFAULT 'queued', error TEXT,
  created_at INTEGER NOT NULL, UNIQUE(message_id,device_id)
);
CREATE INDEX v2_outbox_pending ON v2_outbox(state,next_at,lease_until);
CREATE TABLE v2_rate_limits (
  scope TEXT PRIMARY KEY, window INTEGER NOT NULL, count INTEGER NOT NULL
);
-- CHECK makes preconditions part of the SAME D1 transaction as all mutations.
-- A failed guard rolls back the entire batch, not just its following statement.
CREATE TABLE v2_guard (id INTEGER PRIMARY KEY CHECK(id=1), valid INTEGER NOT NULL CHECK(valid=1));
INSERT INTO v2_guard VALUES(1,1);
