-- colour
-- Reference table of the colours available to assign to a category.

CREATE TABLE IF NOT EXISTS colour (
    colour_id INTEGER CONSTRAINT PK_colour PRIMARY KEY,
    colour_name TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_colour ON colour(colour_name);

INSERT INTO colour (colour_id, colour_name)
SELECT 0, 'blank' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 0);
INSERT INTO colour (colour_id, colour_name)
SELECT 1, 'Red' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 1);
INSERT INTO colour (colour_id, colour_name)
SELECT 2, 'Green' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 2);
INSERT INTO colour (colour_id, colour_name)
SELECT 3, 'Blue' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 3);
INSERT INTO colour (colour_id, colour_name)
SELECT 4, 'Orange' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 4);
INSERT INTO colour (colour_id, colour_name)
SELECT 5, 'Yellow' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 5);
INSERT INTO colour (colour_id, colour_name)
SELECT 6, 'Brown' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 6);
INSERT INTO colour (colour_id, colour_name)
SELECT 7, 'Pink' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 7);
INSERT INTO colour (colour_id, colour_name)
SELECT 8, 'Purple' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 8);
INSERT INTO colour (colour_id, colour_name)
SELECT 9, 'Teal' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 9);
INSERT INTO colour (colour_id, colour_name)
SELECT 10, 'Indigo' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 10);
INSERT INTO colour (colour_id, colour_name)
SELECT 11, 'Mint' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 11);
INSERT INTO colour (colour_id, colour_name)
SELECT 12, 'Cyan' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 12);
