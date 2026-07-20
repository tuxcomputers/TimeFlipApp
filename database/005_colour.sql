-- colour
-- Reference table of the colours available to assign to a category.

CREATE TABLE IF NOT EXISTS colour (
  colour_id     INTEGER CONSTRAINT PK_colour PRIMARY KEY
  , colour_name TEXT NOT NULL
  , device_hex  TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS UN1_colour ON colour(colour_name);

INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 0, 'blank', NULL WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 0);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 1, 'Red', '#ff0000' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 1);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 2, 'Maroon', '#800000' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 2);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 3, 'Brown', '#a52a2a' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 3);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 4, 'Tan', '#d2b48c' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 4);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 5, 'Orange', '#ffa500' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 5);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 6, 'Peach', '#ffdab9' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 6);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 7, 'Gold', '#ffd700' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 7);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 8, 'Yellow', '#ffff00' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 8);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 9, 'Lime', '#00ff00' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 9);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 10, 'Olive', '#808000' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 10);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 11, 'Green', '#008000' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 11);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 12, 'Teal', '#008080' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 12);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 13, 'Cyan', '#00ffff' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 13);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 14, 'Blue', '#0000ff' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 14);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 15, 'Navy', '#000080' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 15);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 16, 'Purple', '#800080' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 16);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 17, 'Magenta', '#ff00ff' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 17);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 18, 'Pink', '#ffc0cb' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 18);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 19, 'Grey', '#808080' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 19);
INSERT INTO colour (colour_id, colour_name, device_hex)
SELECT 20, 'Silver', '#c0c0c0' WHERE NOT EXISTS (SELECT 1 FROM colour WHERE colour_id = 20);
