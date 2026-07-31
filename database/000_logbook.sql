-- logbook (LEGACY — pre-redesign schema, kept only so the not-yet-migrated code in
-- AppDataStore.swift keeps working. Column names intentionally don't follow the conventions in
-- CLAUDE.md; this file and every reference to `logbook` in Swift will be deleted once
-- AppDataStore is rewritten against the device_events/time_entry schema.)

-- Migration (run by hand against a database that predates this rename, see CLAUDE.md):
-- ALTER TABLE logbook RENAME COLUMN facet_id TO face_id;

CREATE TABLE IF NOT EXISTS logbook (
  id              INTEGER CONSTRAINT PK_logbook PRIMARY KEY AUTOINCREMENT
  , event_number  INTEGER
  , face_id       INTEGER NOT NULL
  , started_at_s  REAL NOT NULL
  , duration_s    REAL NOT NULL
  , is_paused     INTEGER NOT NULL
  , activity_name TEXT NOT NULL
  , created_at    REAL NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_logbook ON logbook(event_number);
