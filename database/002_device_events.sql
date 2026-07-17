-- device_events
-- Stores TimeFlip device history data, decoded to human-readable values (not the raw hex
-- payload the device transmits). See docs/database-design.md for the full design rationale,
-- and CLAUDE.md in this folder for the local-time/timezone storage convention.
--
-- Ordering ("is this event newer than what we've already recorded?") and the finalised flag are
-- driven by start_epoch, not event_number. event_number is a counter maintained on the device
-- itself, and a device-side reset (e.g. a battery pull) can make it start counting again from a
-- low number while this table already holds higher event_number values from before the reset --
-- comparing event_number magnitudes directly would then treat a brand new event as older than
-- history it's actually superseding. start_epoch (Unix epoch seconds, derived from the device's
-- own timestamp) doesn't reset, so it's used for that comparison instead; event_number remains
-- the row's UNIQUE lookup key for update-in-place re-ingestion within one continuous device
-- session.

CREATE TABLE IF NOT EXISTS device_events (
  device_events_id      INTEGER CONSTRAINT PK_device_events PRIMARY KEY AUTOINCREMENT
  , event_number        INTEGER NOT NULL
  , event_type_id       INTEGER NOT NULL REFERENCES event_type(event_type_id)
  , device_face         INTEGER NOT NULL CHECK (device_face BETWEEN 1 AND 12)
  , start_time          TEXT NOT NULL
  , start_time_timezone TEXT NOT NULL
  , start_epoch         INTEGER NOT NULL
  , duration_seconds    REAL NOT NULL CHECK (duration_seconds >= 0)
  , is_paused           INTEGER NOT NULL CHECK (is_paused IN (0,1))
  , finalised           INTEGER NOT NULL DEFAULT 0 CHECK (finalised IN (0,1))
  , processed           INTEGER NOT NULL DEFAULT 0 CHECK (processed IN (0,1))
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_device_events ON device_events(event_number);
CREATE INDEX IF NOT EXISTS IN1_device_events ON device_events(start_epoch);
