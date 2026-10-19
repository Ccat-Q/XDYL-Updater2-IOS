-- Additive baseline for the attached D1 worker; never drops existing user data.
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY, public_key TEXT NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_id TEXT NOT NULL, from_user TEXT NOT NULL, to_user TEXT NOT NULL,
  cipher TEXT NOT NULL, ts INTEGER NOT NULL, created_at INTEGER NOT NULL,
  UNIQUE(from_user, msg_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS legacy_message_identity ON messages(from_user, msg_id);
CREATE INDEX IF NOT EXISTS legacy_inbox ON messages(to_user, seq);
CREATE INDEX IF NOT EXISTS legacy_outbox ON messages(from_user, seq);
CREATE TABLE IF NOT EXISTS reads (
  reader TEXT NOT NULL, peer TEXT NOT NULL, upto_seq INTEGER NOT NULL,
  updated_at INTEGER NOT NULL, PRIMARY KEY(reader, peer)
);
