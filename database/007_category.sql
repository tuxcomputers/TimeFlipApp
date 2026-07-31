-- category
-- Named activity category (e.g. an activity mapped to a face), linked to an icon and colour.

CREATE TABLE IF NOT EXISTS category (
  category_id     INTEGER CONSTRAINT PK_category PRIMARY KEY AUTOINCREMENT
  , category_name TEXT NOT NULL
  , icon_id       INTEGER NOT NULL DEFAULT 0 REFERENCES icon(icon_id)
  , colour_id     INTEGER NOT NULL DEFAULT 0 REFERENCES colour(colour_id)
  , project_id    INTEGER NOT NULL DEFAULT 0 REFERENCES project(project_id)
  , daily_limit   INTEGER NOT NULL DEFAULT 0
  , cost          INTEGER NOT NULL DEFAULT 0
  , active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_category ON category(category_name COLLATE NOCASE) WHERE active = 1;

-- Migration (run by hand against a database that predates this column, see CLAUDE.md):
-- ALTER TABLE category ADD COLUMN active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1));

-- Migration (run by hand against a database that predates this index, see CLAUDE.md).
-- Creating it fails if two active rows already share a name, so check first and retire one:
--   SELECT category_name, COUNT(*) FROM category WHERE active = 1
--    GROUP BY category_name COLLATE NOCASE HAVING COUNT(*) > 1;
-- CREATE UNIQUE INDEX IF NOT EXISTS UN1_category ON category(category_name COLLATE NOCASE) WHERE active = 1;

INSERT INTO category (category_id, category_name, icon_id, colour_id)
SELECT 0, 'Unassigned', 0, 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Unassigned');

INSERT INTO category (category_name, icon_id, colour_id)
SELECT 'Break', (SELECT icon_id FROM icon WHERE icon_name = 'ic_break'), 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Break');

INSERT INTO category (category_name, icon_id, colour_id)
SELECT 'Meeting', (SELECT icon_id FROM icon WHERE icon_name = 'ic_meeting'), 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Meeting');
