-- setting
-- Generic key/value store for device/app settings. One row per setting.

CREATE TABLE IF NOT EXISTS setting (
    setting_id INTEGER PRIMARY KEY AUTOINCREMENT,
    setting_name TEXT NOT NULL UNIQUE,
    setting_value TEXT NOT NULL,
    setting_description TEXT
);

INSERT INTO setting (setting_name, setting_value, setting_description) VALUES
    ('double_tap_enabled', '1', 'Whether double-tap gesture detection is enabled; if disabled, double-tap notifications from the device are ignored.'),
    ('double_tap_settings', '{"clickThreshold":20,"limit":10,"latency":20,"window":40}', 'Double-tap detection parameters, seeded from DoubleTapParameters.default in Sources/TimeFlipApp/TimeFlipDoubleTapParameters.swift.'),
    ('led_settings', '{"brightness":50,"blink_interval":15,"blink_length":5,"blink_speed":0}', 'LED settings: brightness (%) and blink_interval (seconds, gap from the end of one blink to the start of the next) seeded from AppState''s ledBrightnessPercent/blinkIntervalSeconds defaults. blink_length (seconds, start-of-blink to end-of-blink) and blink_speed (0-100%, how much of blink_length is spent ramping up to full brightness before fading) have no code equivalent yet, so 0 is a placeholder -- see docs/database-design.md for the full ramp/hold/fade behavior blink_speed controls.'),
    ('blip_time', '5', 'Seconds. While picking up and turning the device to find the desired face, it can pass over other faces briefly, creating unwanted entries for them. Any device_events segment shorter than blip_time is merged into the following segment instead of becoming its own time_entry.'),
    ('real_length_time', '0', NULL)
ON CONFLICT (setting_name) DO NOTHING;
