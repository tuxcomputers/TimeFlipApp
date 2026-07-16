-- face
-- The 12 physical facets of the TimeFlip device, each linked to the category currently assigned
-- to it.

CREATE TABLE IF NOT EXISTS face (
    face_id INTEGER PRIMARY KEY,
    category_id INTEGER NOT NULL REFERENCES category(category_id)
);

INSERT INTO face (face_id, category_id)
SELECT src.face_id, (SELECT category_id FROM category WHERE category_name = 'Unassigned')
FROM (
    SELECT 1 AS face_id UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
    UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12
) AS src
WHERE NOT EXISTS (SELECT 1 FROM face WHERE face.face_id = src.face_id);
