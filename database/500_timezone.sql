-- timezone
-- Reference list of IANA time zones (e.g. Australia/Sydney), for the debug database's own rows.

CREATE TABLE IF NOT EXISTS timezone (
  timezone_id     INTEGER CONSTRAINT PK_timezone PRIMARY KEY AUTOINCREMENT
  , timezone_name TEXT NOT NULL
  , display_name  TEXT
  , active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_timezone ON timezone(timezone_name);

INSERT INTO timezone (timezone_id, timezone_name, display_name)
SELECT 0, 'Unknown', 'Unknown'
WHERE NOT EXISTS (SELECT 1 FROM timezone WHERE timezone_id = 0);
