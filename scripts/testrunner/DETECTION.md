# How the test runner detects device/app state

Reference for anyone (human or Claude) extending the runner. The runner never asks the
app over any API -- it reads the same SQLite database the app writes to, at
`~/Library/Application Support/TimeFlip/appdata.sqlite`. Everything below is a plain
`sqlite3` query against that file (or the concrete file it resolves to -- see the symlink
note). All the helpers live in [`session_setup.py`](session_setup.py); step-level checks
(`sql_query` / `wait_for_sql`) live in [`actions.py`](actions.py).

## The two channels

The app exposes state to us two ways:

1. **Settings and domain tables** -- durable rows the app maintains (`setting`,
   `device_event`, `time_entry`, ...). Query these for *current state* (which database,
   is the device paused).
2. **`debug_log`** -- every dev-only `DeveloperMode.debugPrint(tag, message)` is also
   persisted here (tag, message, autoincrement `debug_log_id`), via `logSink` wired in
   `ApplicationDelegate`. Query this for *events that just happened* (a reconnect, a
   history fetch finishing, a factory reset confirming). This is our side-effect channel:
   to detect that a physical/UI action took effect, find the debug line the app logs on
   that path rather than waiting on a chat confirmation.

## Which database is active -- `setting.db_type`

Stored as JSON in the `setting` table, e.g. `{"type":"test"}`. The app stamps it into
each file when the file is first created and never changes it; the value tracks which
physical file `appdata.sqlite` is symlinked to (`production.sqlite` / `test.sqlite`).

```sql
SELECT setting_value FROM setting WHERE setting_name='db_type';   -- -> {"type":"..."}
```

Helper: `_read_db_type(db_path)`. (Same value the app now shows as the TEST/PROD tag in
the menu bar under developer mode.)

## Is the device paused or timing -- `device_event.is_paused`

`device_event` holds one row per device-reported timing segment (a facet flip or a
pause); see [`../../database/003_device_event.sql`](../../database/003_device_event.sql).
The **most recent** segment's `is_paused` flag tells you the current state.

Order by `start_epoch` (indexed Unix seconds), **not** `event_number` -- the device's
event counter resets on factory reset and isn't safe for wall-clock ordering (see
[`../../database/CLAUDE.md`](../../database/CLAUDE.md)).

```sql
SELECT is_paused FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;
```

Helper: `_last_event_is_paused(db_path)` -> `True` (paused) / `False` (timing) / `None`
(no events yet). Used by `ensure_not_timing_on_production()`, the pre-flight gate that
refuses to start a run while we're on production and the device is mid-timing -- because
the run switches to the test DB and factory-resets the device at the end, which would
interrupt a real, in-progress timing event.

Caveat: this reflects the last state the app **synced** to the DB, not necessarily the
literal instant. Right after a flip there can be a short sync lag; the production branch
of `ensure_known_state()` forces a fresh history fetch (by restarting the app) precisely
so real history is captured before any switch.

## Device connected / reconnected -- `debug_log` login row

The app logs `Login accepted, code=0x02` (tag `TimeFlip`) on every successful device
login.

```sql
SELECT debug_log_id FROM debug_log
 WHERE tag='TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > :since
 ORDER BY debug_log_id DESC LIMIT 1;
```

Helper: `_wait_for_reconnect(...)`. Match on `debug_log_id` (unique, monotonic), never on
the message text -- the login line repeats verbatim, so text comparison never detects a
*new* login.

## History fetch finished -- `debug_log` completion marker

`HistoryIngestor.refreshHistory()` logs `history fetch complete: trigger=<trigger>` (tag
`history`) on every exit path -- unlike the older "DB refreshed" text, which only
appeared on the nothing-changed branch. Helper: `_wait_for_history_fetch_complete(...)`.

## Factory reset confirmed -- `debug_log`

`Factory reset confirmed...` (tag `TimeFlip`) marks the cleanup reset landing; see
`reset_device_for_cleanup()`.

## The `since_id` / per-file gotcha (read this before adding a `debug_log` wait)

`debug_log` **persists across app restarts**, and `debug_log_id` is **per file, not
global**. Two consequences:

- Capture a baseline `MAX(debug_log_id)` (`_latest_debug_log_id`) **before** the action
  you're waiting on, and scope the wait to `debug_log_id > since_id`. An unscoped query
  matches a stale pre-action row and returns instantly.
- Read that baseline from the **concrete file the switch will land on**, not through the
  `appdata.sqlite` symlink. On a prod->test switch, `test.sqlite`'s id sequence restarts
  at 1, so a `since_id` carried over from production's much larger sequence would never be
  exceeded (guaranteeing a false timeout). After a switch, pin the concrete path with
  `os.path.realpath(db_path)` and use `since_id=0`. `_sibling_db_path()` resolves a named
  sibling file directly. This is why `ensure_known_state()` returns the resolved concrete
  path and the whole run queries *that*, not the symlink.
