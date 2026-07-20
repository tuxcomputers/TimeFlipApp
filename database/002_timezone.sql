-- timezone
-- Reference list of IANA time zones (e.g. Australia/Sydney). The date/time tables reference a row
-- here by id (see their `timezone_id` / `<name>_timezone_id` columns) instead of storing the IANA
-- identifier inline. Rows are populated from the OS's known identifiers at runtime rather than by
-- hand (see AppDataStore.resolveTimezoneID), so this file seeds only the id 0 "Unknown" sentinel
-- that those FK columns default to.

CREATE TABLE IF NOT EXISTS timezone (
  timezone_id     INTEGER CONSTRAINT PK_timezone PRIMARY KEY AUTOINCREMENT
  , timezone_name TEXT NOT NULL
  , display_name  TEXT
  , is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_timezone ON timezone(timezone_name);

INSERT INTO timezone (timezone_id, timezone_name, display_name)
SELECT 0, 'Unknown', 'Unknown'
WHERE NOT EXISTS (SELECT 1 FROM timezone WHERE timezone_id = 0);
