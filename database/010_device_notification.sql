-- device_notification
-- Point-in-time device notifications that aren't timing segments (double tap, battery level,
-- system state, device info, event log) — see event_type for the full list. `payload` holds
-- whatever value that event type carries (e.g. a battery percentage or system state code),
-- decoded to a human-readable string rather than the device's raw encoding.
--
-- start_time/start_epoch use the same naming as device_event (rather than e.g. occurred_at) so
-- both device tables can be queried/ordered the same way; start_epoch is indexed for that.

CREATE TABLE IF NOT EXISTS device_notification (
  device_notification_id  INTEGER CONSTRAINT PK_device_notification PRIMARY KEY AUTOINCREMENT
  , event_type_id         INTEGER NOT NULL REFERENCES event_type(event_type_id)
  , start_time            TEXT NOT NULL
  , timezone_id           INTEGER NOT NULL DEFAULT 0 REFERENCES timezone(timezone_id)
  , start_epoch           INTEGER NOT NULL
  , payload               TEXT
);

CREATE INDEX IF NOT EXISTS IN1_device_notification ON device_notification(start_epoch);
