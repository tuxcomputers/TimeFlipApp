-- device_event
-- One row per device-reported timing segment (a face flip or pause).

CREATE TABLE IF NOT EXISTS device_event (
  device_event_id    INTEGER CONSTRAINT PK_device_event PRIMARY KEY AUTOINCREMENT
  , event_number     INTEGER NOT NULL
  , event_type_id    INTEGER NOT NULL REFERENCES event_type(event_type_id)
  , device_face      INTEGER NOT NULL CHECK (device_face BETWEEN 1 AND 13)
  , start_time       TEXT NOT NULL
  , timezone_id      INTEGER NOT NULL DEFAULT 0 REFERENCES timezone(timezone_id)
  , start_epoch      INTEGER NOT NULL
  , duration_seconds REAL NOT NULL CHECK (duration_seconds >= 0)
  , paused           INTEGER NOT NULL CHECK (paused IN (0,1))
  , finalised        INTEGER NOT NULL DEFAULT 0 CHECK (finalised IN (0,1))
  , processed        INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
);

-- Migration (run by hand against a database whose device_face CHECK still stops at 12, see CLAUDE.md).
-- SQLite has no ALTER for a CHECK, so this is the table rebuild from its own "Making Other Kinds Of
-- Table Schema Changes" procedure. foreign_keys is turned off around it so dropping the old table
-- does not take time_entry's references with it, and foreign_key_check confirms they all still land:
-- PRAGMA foreign_keys = OFF;
-- BEGIN TRANSACTION;
-- CREATE TABLE device_event_new (
--   device_event_id    INTEGER CONSTRAINT PK_device_event PRIMARY KEY AUTOINCREMENT
--   , event_number     INTEGER NOT NULL
--   , event_type_id    INTEGER NOT NULL REFERENCES event_type(event_type_id)
--   , device_face      INTEGER NOT NULL CHECK (device_face BETWEEN 1 AND 13)
--   , start_time       TEXT NOT NULL
--   , timezone_id      INTEGER NOT NULL DEFAULT 0 REFERENCES timezone(timezone_id)
--   , start_epoch      INTEGER NOT NULL
--   , duration_seconds REAL NOT NULL CHECK (duration_seconds >= 0)
--   , paused           INTEGER NOT NULL CHECK (paused IN (0,1))
--   , finalised        INTEGER NOT NULL DEFAULT 0 CHECK (finalised IN (0,1))
--   , processed        INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
-- );
-- INSERT INTO device_event_new SELECT * FROM device_event;
-- DROP TABLE device_event;
-- ALTER TABLE device_event_new RENAME TO device_event;
-- CREATE UNIQUE INDEX IF NOT EXISTS UN1_device_event ON device_event(event_number, start_epoch);
-- CREATE INDEX IF NOT EXISTS IN1_device_event ON device_event(start_epoch);
-- PRAGMA foreign_key_check;
-- COMMIT;
-- PRAGMA foreign_keys = ON;

CREATE UNIQUE INDEX IF NOT EXISTS UN1_device_event ON device_event(event_number, start_epoch);
CREATE INDEX IF NOT EXISTS IN1_device_event ON device_event(start_epoch);
