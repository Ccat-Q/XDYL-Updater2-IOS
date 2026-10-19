CREATE TABLE v2_legacy_bindings (
  subject TEXT PRIMARY KEY,device_id TEXT NOT NULL,
  key_revision INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 1,
  default_algorithm TEXT NOT NULL CHECK(default_algorithm IN('X25519','P256')),
  enabled INTEGER NOT NULL DEFAULT 1
);
-- Do not infer historical ownership from a mutable username alone. A legacy
-- user binds this mapping only after successful main-account authentication.
CREATE TABLE v2_legacy_users (
  username TEXT PRIMARY KEY,subject TEXT NOT NULL
);
CREATE TABLE v2_legacy_link (
  legacy_seq INTEGER PRIMARY KEY,message_id TEXT NOT NULL UNIQUE,
  request_hash TEXT NOT NULL,algorithm TEXT NOT NULL,
  sender_public_key TEXT NOT NULL,recipient_public_key TEXT NOT NULL
);
CREATE TABLE v2_schema(version INTEGER PRIMARY KEY);
INSERT INTO v2_schema VALUES(4);
