-- debug_log
-- Every dev-only debug message (see DeveloperMode.debugPrint in DeveloperConfigStore.swift) is
-- additionally recorded here whenever the `debug` setting's enabled field is true (see
-- 009_setting.sql), so a test session can be analyzed after the fact from the database instead
-- of relying on a terminal transcript that was never captured.

CREATE TABLE IF NOT EXISTS debug_log (
    debug_log_id INTEGER CONSTRAINT PK_debug_log PRIMARY KEY AUTOINCREMENT,
    logged_at TEXT NOT NULL,
    logged_at_timezone TEXT NOT NULL,
    tag TEXT NOT NULL,
    message TEXT NOT NULL
);
