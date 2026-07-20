-- integration_event_cursors (LEGACY — pre-redesign schema, kept only so the not-yet-migrated
-- code in AppDataStore.swift keeps working. Column names intentionally don't follow the
-- conventions in CLAUDE.md; this file and every reference to `integration_event_cursors` in
-- Swift will be deleted once AppDataStore is rewritten against the device_events/time_entry
-- schema.)

CREATE TABLE IF NOT EXISTS integration_event_cursors (
  target            TEXT NOT NULL
  , identifier      TEXT NOT NULL
  , last_sent_ev    INTEGER
  , attempts        INTEGER NOT NULL DEFAULT 0
  , last_error      TEXT
  , last_success_ev INTEGER
  , updated_at      REAL
  , CONSTRAINT PK1_integration_event_cursors PRIMARY KEY (target, identifier)
);
