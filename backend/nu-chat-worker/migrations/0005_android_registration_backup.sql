-- Recovered from the verified production schema on 2026-11-15.
-- This file is a local migration only; it has not been applied remotely here.
CREATE TABLE IF NOT EXISTS device_registry (
  subject TEXT NOT NULL,
  device_code TEXT NOT NULL,
  platform TEXT NOT NULL,
  app_version TEXT,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (subject, device_code)
);
CREATE TABLE IF NOT EXISTS v2_key_backups (
  subject TEXT PRIMARY KEY,
  pwd_blob TEXT NOT NULL,
  code_blob TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  kdf TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
