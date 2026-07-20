# Database ER diagram

Entity-relationship diagram of the SQLite schema defined by the `NNN_*.sql` files in this
directory. Generated from the DDL; keep it in sync when the schema changes.

Foreign keys (referencing → referenced):

- `device_events.event_type_id` → `event_type`
- `device_notifications.event_type_id` → `event_type`
- `category.icon_id` → `icon`
- `category.colour_id` → `colour`
- `face.category_id` → `category`
- `time_entry.category_id` → `category`
- `time_entry.device_events_id` → `device_events`

Standalone tables with no foreign keys — `logbook`, `integration_event_cursors`, `setting`,
`debug_log` — are shown but unconnected.

```mermaid
erDiagram
    event_type ||--o{ device_events : "classifies"
    event_type ||--o{ device_notifications : "classifies"
    icon ||--o{ category : "shown by"
    colour ||--o{ category : "coloured by"
    category ||--o{ face : "assigned to"
    category ||--o{ time_entry : "accrues"
    device_events ||--o{ time_entry : "derived from"

    event_type {
        INTEGER event_type_id PK
        TEXT    event_name
    }

    device_events {
        INTEGER device_events_id PK
        INTEGER event_number
        INTEGER event_type_id FK
        INTEGER device_face
        TEXT    start_time
        TEXT    start_time_timezone
        INTEGER start_epoch
        REAL    duration_seconds
        INTEGER is_paused
        INTEGER finalised
        INTEGER processed
    }

    device_notifications {
        INTEGER device_notifications_id PK
        INTEGER event_type_id FK
        TEXT    start_time
        TEXT    start_time_timezone
        INTEGER start_epoch
        TEXT    payload
    }

    icon {
        INTEGER icon_id PK
        TEXT    icon_name
    }

    colour {
        INTEGER colour_id PK
        TEXT    colour_name
        TEXT    device_hex
    }

    category {
        INTEGER category_id PK
        TEXT    category_name
        INTEGER icon_id FK
        INTEGER colour_id FK
        INTEGER daily_limit
    }

    face {
        INTEGER face_id PK
        INTEGER category_id FK
    }

    time_entry {
        INTEGER time_entry_id PK
        INTEGER category_id FK
        INTEGER device_events_id FK
        TEXT    started_at
        TEXT    started_at_timezone
        TEXT    ended_at
        TEXT    ended_at_timezone
        REAL    duration_seconds
        INTEGER synced_to_google_calendar
    }

    logbook {
        INTEGER id PK
        INTEGER event_number
        INTEGER facet_id
        REAL    started_at_s
        REAL    duration_s
        INTEGER is_paused
        TEXT    activity_name
        REAL    created_at
    }

    integration_event_cursors {
        TEXT    target PK
        TEXT    identifier PK
        INTEGER last_sent_ev
        INTEGER attempts
        TEXT    last_error
        INTEGER last_success_ev
        REAL    updated_at
    }

    setting {
        INTEGER setting_id PK
        TEXT    setting_name
        TEXT    setting_value
        TEXT    setting_description
    }

    debug_log {
        INTEGER debug_log_id PK
        TEXT    logged_at
        TEXT    logged_at_timezone
        TEXT    tag
        TEXT    message
    }
```
