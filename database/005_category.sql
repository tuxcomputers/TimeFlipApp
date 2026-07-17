-- category
-- Named activity category (e.g. an activity mapped to a facet), linked to the icon and colour
-- assigned to it.

CREATE TABLE IF NOT EXISTS category (
    category_id INTEGER CONSTRAINT PK_category PRIMARY KEY AUTOINCREMENT,
    category_name TEXT NOT NULL,
    icon_id INTEGER NOT NULL DEFAULT 0 REFERENCES icon(icon_id),
    colour_id INTEGER NOT NULL DEFAULT 0 REFERENCES colour(colour_id)
);

INSERT INTO category (category_name, icon_id, colour_id)
SELECT 'Unassigned', 0, 0
WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Unassigned');
