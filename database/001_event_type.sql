-- event_type
-- Reference table of the different event types the TimeFlip device can trigger.

CREATE TABLE IF NOT EXISTS event_type (
  event_type_id INTEGER PRIMARY KEY
  , event_name  TEXT NOT NULL UNIQUE
);

INSERT INTO event_type (event_type_id, event_name) VALUES
    (1, 'facet_flip'),
    (2, 'pause'),
    (3, 'double_tap'),
    (4, 'auto_pause_minutes'),
    (5, 'battery_level'),
    (6, 'system_state'),
    (7, 'device_info'),
    (8, 'event_log')
ON CONFLICT (event_type_id) DO NOTHING;
