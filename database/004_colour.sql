-- colour
-- Reference table of the colours available to assign to a category.

CREATE TABLE IF NOT EXISTS colour (
    colour_id INTEGER PRIMARY KEY,
    colour_name TEXT NOT NULL UNIQUE
);

INSERT INTO colour (colour_id, colour_name) VALUES
    (0, 'blank'),
    (1, 'Red'),
    (2, 'Green'),
    (3, 'Blue'),
    (4, 'Orange'),
    (5, 'Yellow'),
    (6, 'Brown'),
    (7, 'Pink'),
    (8, 'Purple'),
    (9, 'Teal'),
    (10, 'Indigo'),
    (11, 'Mint'),
    (12, 'Cyan')
ON CONFLICT (colour_id) DO NOTHING;
