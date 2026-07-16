-- device_events
-- Stores TimeFlip device history data, decoded to human-readable values (not the raw hex
-- payload the device transmits). See docs/database-design.md for the full design rationale,
-- and CLAUDE.md in this folder for the local-time/timezone storage convention.

CREATE TABLE IF NOT EXISTS device_events (
  device_events_id      INTEGER PRIMARY KEY AUTOINCREMENT
  , event_number        INTEGER NOT NULL UNIQUE
  , event_type_id       INTEGER NOT NULL REFERENCES event_type(event_type_id)
  , device_face         INTEGER NOT NULL CHECK (device_face BETWEEN 1 AND 12)
  , started_at          TEXT NOT NULL
  , started_at_timezone TEXT NOT NULL
  , duration_seconds    REAL NOT NULL CHECK (duration_seconds >= 0)
  , is_paused           INTEGER NOT NULL CHECK (is_paused IN (0,1))
  , finalised           INTEGER NOT NULL DEFAULT 0 CHECK (finalised IN (0,1))
  , processed           INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
);
