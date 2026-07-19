-- setting
-- Generic key/value store for device/app settings. One row per setting.

CREATE TABLE IF NOT EXISTS setting (
    setting_id INTEGER CONSTRAINT PK_setting PRIMARY KEY AUTOINCREMENT,
    setting_name TEXT NOT NULL,
    setting_value TEXT NOT NULL,
    setting_description TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_setting ON setting(setting_name);

-- Every setting_value is a JSON object, even single-value settings, so reading this table never
-- needs to branch on which row it is -- callers always decode setting_value as JSON.
INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'db_type', '{"type":"production"}', 'type: "production" or "test" -- which physical database file (see AppDataStore.ensureDatabaseSymlink) this row lives in. Set once, when that file is first created, and never changed afterward: production.sqlite always seeds as "production" via this default; scripts/use-test-database.sh overrides a freshly-created test.sqlite to "test" immediately after seeding it. Used as a pre-testing safety check (see Tests/CLAUDE.md) -- if this reads "production" during what is supposed to be a testing session, the appdata.sqlite symlink was never repointed at test.sqlite, and testing must not proceed.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'db_type');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'double_tap_settings', '{"enabled":true,"clickThreshold":90,"limit":20,"latency":50,"window":50}', 'Double-tap detection settings. enabled controls whether double-tap gesture detection is on; if false, double-tap notifications from the device are ignored. clickThreshold/limit/latency/window are the accelerometer parameters, seeded from DoubleTapParameters.default in Sources/TimeFlipApp/TimeFlipDoubleTapParameters.swift -- captured from a real device''s actual registers via Tests/Bench (see Tests/Bench/device_register_snapshot.json), not an arbitrary guess.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'double_tap_settings');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'led_settings', '{"brightness":50,"blink_interval":15}', 'LED settings: brightness (%, device cmd 0x09) and blink_interval (seconds, device cmd 0x0A) -- the only two LED properties the vendor protocol exposes (see docs/TimeFlip2 BLE Protocol v4.3.md), seeded from AppState''s ledBrightnessPercent/blinkIntervalSeconds defaults.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'led_settings');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'auto_pause_minutes', '{"minutes":0}', 'minutes: delay after which the device pauses itself if the facet hasn''t changed (device cmd 0x05; 0 disables, matching the vendor protocol''s own disabled-by-default behavior; the device itself only supports whole-minute granularity, so this can''t be made finer). The timer resets every time the facet changes.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'auto_pause_minutes');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'blip_time', '{"seconds":5}', 'seconds: while picking up and turning the device to find the desired face, it can pass over other faces briefly, creating unwanted entries for them. Any device_events segment shorter than this is merged into the following segment instead of becoming its own time_entry.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'blip_time');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'firmware_check', '{"last_alert":"' || date('now', 'localtime') || '","interval_months":2}', 'last_alert (local date, YYYY-MM-DD) is when the firmware-update alert was last shown/acknowledged, seeded to the date this row was first inserted. interval_months is how many calendar months after last_alert before the user is prompted again to connect the device to the official TimeFlip app and check for a firmware update -- there is no documented way for this app to check the firmware version itself, see docs/timeflip.md. The Settings button that dismisses the alert resets last_alert to today regardless of whether the user actually checked, pushing the next alert out by interval_months either way.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'firmware_check');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'pause_on_lock', '{"enabled":true}', 'enabled: when true, pausing via the app (command 0x06) also engages device lock mode (command 0x04) so the device cannot be flipped to a new facet while paused. Does not apply when pause is triggered by a double-tap on the device itself -- that pause is left unlocked.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'pause_on_lock');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'fetch_history_interval_seconds', '{"seconds":10}', 'seconds: how often the app sends a history fetch request (command 0x02) to the device to pick up any entries not yet seen, in addition to the fetches already triggered by live facet/pause events. Stored in seconds; a future Settings UI will expose this in minutes and convert it before saving here.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'fetch_history_interval_seconds');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'display_seconds', '{"enabled":true}', 'enabled: when true, the menu bar duration display includes a seconds component (H:MM:SS) and refreshes every second; when false, it shows H:MM and refreshes every minute.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'display_seconds');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'low_battery_level', '{"percent":5}', 'percent: battery_level (0-100, from the Battery Level characteristic 0x2A19) at or below which the device is considered low on battery and the app should warn the user. No such warning is implemented yet -- this is just the threshold setting.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'low_battery_level');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'google_account', '{}', 'Cached identity of the connected Google account -- name and email from the OpenID Connect userinfo endpoint. Empty object until the first successful fetch after Google sign-in; populated once and then reused so the userinfo endpoint is not called again on every launch or Settings open (see GoogleIntegrationCoordinator.loadAccountInfo). Cleared back to {} on sign-out so a later sign-in with a different account re-fetches.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'google_account');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'debug', '{"enabled":true,"to_file":false,"directory":"~/Documents/TimeFlip"}', 'NOT YET IMPLEMENTED -- placeholder for a planned feature, see docs/TODO-devmode.md. Intent: enabled controls whether the same messages DeveloperMode.debugPrint sends to the terminal (when DeveloperMode.isEnabled is true, for local development) are gathered at all for this user-facing setting; to_file controls whether those messages are ALSO written to a log file, so a non-technical end user can turn this on and send the file back for support without running the app from a terminal -- defaulted to false since the file-writing side of this is not built yet. directory is the folder the log file is written to; a future Preferences UI will let the user override this via a folder-selection dialog. The log filename format and per-launch behavior are intentionally not stored here -- see docs/TODO-devmode.md.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'debug');

INSERT INTO setting (setting_name, setting_value, setting_description)
SELECT 'daily_reset_time', '{"hour":3,"minute":0}', 'NOT YET IMPLEMENTED -- placeholder for a planned feature. hour (0-23) and minute (0-59), local time, at which each category''s tracked-time-vs-category.daily_limit accounting rolls over to a new day (default 3 AM, not midnight, so a session spanning midnight isn''t split). A future Preferences UI will let the user override this.'
WHERE NOT EXISTS (SELECT 1 FROM setting WHERE setting_name = 'daily_reset_time');
