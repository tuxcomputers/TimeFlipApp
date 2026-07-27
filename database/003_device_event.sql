-- device_event
-- One row per device-reported timing segment (a facet flip or pause).

CREATE TABLE IF NOT EXISTS device_event (
  device_event_id    INTEGER CONSTRAINT PK_device_event PRIMARY KEY AUTOINCREMENT
  , event_number     INTEGER NOT NULL
  , event_type_id    INTEGER NOT NULL REFERENCES event_type(event_type_id)
  , device_face      INTEGER NOT NULL CHECK (device_face BETWEEN 1 AND 12)
  , start_time       TEXT NOT NULL
  , timezone_id      INTEGER NOT NULL DEFAULT 0 REFERENCES timezone(timezone_id)
  , start_epoch      INTEGER NOT NULL
  , duration_seconds REAL NOT NULL CHECK (duration_seconds >= 0)
  , is_paused        INTEGER NOT NULL CHECK (is_paused IN (0,1))
  , finalised        INTEGER NOT NULL DEFAULT 0 CHECK (finalised IN (0,1))
  , processed        INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_device_event ON device_event(event_number, start_epoch);
CREATE INDEX IF NOT EXISTS IN1_device_event ON device_event(start_epoch);
