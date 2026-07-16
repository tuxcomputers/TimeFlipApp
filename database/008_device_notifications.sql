-- device_notifications
-- Point-in-time device notifications that aren't timing segments (double tap, battery level,
-- system state, device info, event log) — see event_type for the full list. `payload` holds
-- whatever value that event type carries (e.g. a battery percentage or system state code),
-- decoded to a human-readable string rather than the device's raw encoding.

CREATE TABLE IF NOT EXISTS device_notifications (
    device_notifications_id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type_id INTEGER NOT NULL REFERENCES event_type(event_type_id),
    occurred_at TEXT NOT NULL,
    occurred_at_timezone TEXT NOT NULL,
    payload TEXT
);
