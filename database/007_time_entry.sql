-- time_entry
-- A single tracked time span, linked to the category it was logged against.

CREATE TABLE IF NOT EXISTS time_entry (
    time_entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id INTEGER NOT NULL REFERENCES category(category_id),
    device_events_id INTEGER NOT NULL REFERENCES device_events(device_events_id),
    started_at TEXT NOT NULL,
    started_at_timezone TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    ended_at_timezone TEXT NOT NULL,
    duration_seconds REAL NOT NULL CHECK (duration_seconds >= 0),
    synced_to_google_calendar INTEGER NOT NULL DEFAULT 0 CHECK (synced_to_google_calendar IN (0, 1))
);
