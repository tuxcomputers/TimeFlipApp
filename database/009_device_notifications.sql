-- device_notifications
-- Point-in-time device notifications that aren't timing segments (double tap, battery level,
-- system state, device info, event log) — see event_type for the full list. `payload` holds
-- whatever value that event type carries (e.g. a battery percentage or system state code),
-- decoded to a human-readable string rather than the device's raw encoding.
--
-- start_time/start_epoch use the same naming as device_events (rather than e.g. occurred_at) so
-- both device tables can be queried/ordered the same way; start_epoch is indexed for that.

CREATE TABLE IF NOT EXISTS device_notifications (
    device_notifications_id INTEGER CONSTRAINT PK_device_notifications PRIMARY KEY AUTOINCREMENT,
    event_type_id INTEGER NOT NULL REFERENCES event_type(event_type_id),
    start_time TEXT NOT NULL,
    start_time_timezone TEXT NOT NULL,
    start_epoch INTEGER NOT NULL,
    payload TEXT
);

CREATE INDEX IF NOT EXISTS IN1_device_notifications ON device_notifications(start_epoch);
