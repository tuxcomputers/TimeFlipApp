-- category
-- Named activity category (e.g. an activity mapped to a facet), linked to an icon and colour.

CREATE TABLE IF NOT EXISTS category (
  category_id     INTEGER CONSTRAINT PK_category PRIMARY KEY AUTOINCREMENT
  , category_name TEXT NOT NULL
  , icon_id       INTEGER NOT NULL DEFAULT 0 REFERENCES icon(icon_id)
  , colour_id     INTEGER NOT NULL DEFAULT 0 REFERENCES colour(colour_id)
  , project_id    INTEGER NOT NULL DEFAULT 0 REFERENCES project(project_id)
  , daily_limit   INTEGER NOT NULL DEFAULT 0
  , cost          INTEGER NOT NULL DEFAULT 0
);

-- Unassigned is pinned to category_id 0 (a fixed sentinel, like the blank colour) so the
-- colour-update path can skip it with `category_id >= 1` -- it must never be given a colour.
INSERT INTO category (category_id, category_name, icon_id, colour_id)
SELECT 0, 'Unassigned', 0, 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Unassigned');

INSERT INTO category (category_name, icon_id, colour_id)
SELECT 'Break', (SELECT icon_id FROM icon WHERE icon_name = 'ic_break'), 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Break');

INSERT INTO category (category_name, icon_id, colour_id)
SELECT 'Meeting', (SELECT icon_id FROM icon WHERE icon_name = 'ic_meeting'), 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Meeting');
