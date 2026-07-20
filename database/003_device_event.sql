-- device_event
-- Stores TimeFlip device history data, decoded to human-readable values (not the raw hex
-- payload the device transmits). See docs/database-design.md for the full design rationale,
-- and CLAUDE.md in this folder for the local-time/timezone storage convention.
--
-- Ordering ("is this event newer than what we've already recorded?") and the finalised flag are
-- driven by start_epoch, not event_number. event_number is a counter maintained on the device
-- itself, and a device-side reset (e.g. a battery pull, or a reset from the official app) can
-- make it start counting again from a low number while this table already holds higher
-- event_number values from before the reset -- comparing event_number magnitudes directly would
-- then treat a brand new event as older than history it's actually superseding. start_epoch
-- (Unix epoch seconds, derived from the device's own timestamp) doesn't reset, so it's used for
-- that comparison instead.
--
-- Matching a row already seen ("have I recorded this exact segment before?") uses the composite
-- (event_number, start_epoch) pair, not event_number alone: after a reset, event_number can be
-- reused for a completely different segment, so a bare UNIQUE(event_number) would either block
-- that new segment from being inserted, or (if matched on event_number alone) silently overwrite
-- the unrelated old row. start_epoch alone isn't unique either -- the device only reports
-- whole-second timestamps (see docs/TimeFlip2 BLE Protocol v4.3.md's 0x07/0x08 and the flip
-- timestamp field), so two genuinely different segments (e.g. a quick flip across a facet while
-- searching for the right one) can share the same start_epoch second. The combination of both is
-- what's actually unique in practice -- see AppDataStore.recordDeviceEvent for the full matching
-- logic.

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
