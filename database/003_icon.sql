-- icon
-- Reference table of activity icons available to assign to a facet. `icon_name` is the
-- identifier the app uses to locate the icon asset (see
-- Sources/TimeFlipApp/ActivityIconLoader.swift).

CREATE TABLE IF NOT EXISTS icon (
    icon_id INTEGER PRIMARY KEY,
    icon_name TEXT NOT NULL UNIQUE
);

INSERT INTO icon (icon_id, icon_name) VALUES
    (0, 'blank'),
    (1, 'ic_admin'),
    (2, 'ic_agile'),
    (3, 'ic_brainstorming'),
    (4, 'ic_break'),
    (5, 'ic_bugs'),
    (6, 'ic_calls'),
    (7, 'ic_camera'),
    (8, 'ic_chat'),
    (9, 'ic_client'),
    (10, 'ic_code'),
    (11, 'ic_consult'),
    (12, 'ic_design'),
    (13, 'ic_document'),
    (14, 'ic_edit'),
    (15, 'ic_emails'),
    (16, 'ic_facebook'),
    (17, 'ic_fitness'),
    (18, 'ic_games'),
    (19, 'ic_instagram'),
    (20, 'ic_internet'),
    (21, 'ic_logistics'),
    (22, 'ic_marketing'),
    (23, 'ic_media'),
    (24, 'ic_meeting'),
    (25, 'ic_money'),
    (26, 'ic_music'),
    (27, 'ic_office'),
    (28, 'ic_presentation'),
    (29, 'ic_project'),
    (30, 'ic_quotation'),
    (31, 'ic_reading'),
    (32, 'ic_report'),
    (33, 'ic_shopping'),
    (34, 'ic_studying'),
    (35, 'ic_support'),
    (36, 'ic_test'),
    (37, 'ic_tv'),
    (38, 'ic_twitter'),
    (39, 'ic_urgent'),
    (40, 'ic_ux'),
    (41, 'ic_write'),
    (42, 'ic_you_tube')
ON CONFLICT (icon_id) DO NOTHING;
