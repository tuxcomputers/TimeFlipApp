# How the test runner detects device/app state

Reference for anyone (human or Claude) extending the runner. The runner never asks the
app over any API -- it reads the same SQLite database the app writes to, at
`~/Library/Application Support/TimeFlip/appdata.sqlite`. Everything below is a plain
`sqlite3` query against that file (or the concrete file it resolves to -- see
[Pitfalls](#pitfalls-read-before-adding-a-debug_log-wait)). Helpers live in
[`session_setup.py`](session_setup.py); step-level checks (`sql_query` / `wait_for_sql`)
live in [`actions.py`](actions.py).

State comes from two places: **durable tables** (`setting`, `device_event`, ...) for
*current state*, and the **`debug_log`** table for *events that just happened*. Every
dev-only `DeveloperMode.debugPrint(tag, message)` is persisted to `debug_log` (with an
autoincrement `debug_log_id`) via `logSink` wired in `ApplicationDelegate` -- so to detect
that a physical/UI action took effect, poll for the line the app logs on that path.

---

## Start conditions and reaching them

The **start test conditions** (the state every run must reach before the first checklist) and the
per-current-state paths that funnel to them live in [START-STATES.md](START-STATES.md). This file
covers only *how* each thing is detected; that file covers *what* state a run needs and the steps
to get there.

---

## Detecting which DB is being used (Prod or Test)

`setting.db_type` is JSON, e.g. `{"type":"test"}`. Stamped into each file when it is first
created and never changed; tracks which physical file `appdata.sqlite` links to
(`production.sqlite` / `test.sqlite`).

```sql
SELECT setting_value FROM setting WHERE setting_name = 'db_type';   -- -> {"type":"..."}
```

Helper: `_read_db_type(db_path)`. (Same value the app shows as the TEST/PROD tag in the
menu bar under developer mode.)

---

## Detecting if the device is paused (vs timing an activity)

`device_event` has one row per timing segment (a face flip or a pause), with an
`paused` flag; see [`../../database/003_device_event.sql`](../../database/003_device_event.sql).
The **most recent** segment's flag is the current state. Order by `start_epoch` (indexed
Unix seconds), **not** `event_number` -- the device's counter resets on factory reset and
isn't safe for wall-clock ordering (see [`../../database/CLAUDE.md`](../../database/CLAUDE.md)).

```sql
SELECT paused FROM device_event ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;
-- 1 = paused, 0 = timing, no rows = no events yet
```

Helper: `_last_event_paused(db_path)` -> `True` / `False` / `None`. Used by
`ensure_not_timing_on_production()`, the pre-flight gate that refuses to start a run while
on production with the device mid-timing (the run switches to test and factory-resets the
device at the end, which would interrupt a real timing event).

Caveat: reflects the last state the app **synced**, not the literal instant -- right after
a flip there can be a short sync lag.

---

## Detecting if the device is connected / reconnected

The app logs `Login accepted, code=0x02` (tag `TimeFlip`) on every successful login.

```sql
SELECT debug_log_id FROM debug_log
 WHERE tag = 'TimeFlip' AND message LIKE 'Login accepted%' AND debug_log_id > :since
 ORDER BY debug_log_id DESC LIMIT 1;
```

Helper: `_wait_for_reconnect(...)`. Match on `debug_log_id` (unique, monotonic), never on
message text -- the login line repeats verbatim, so text comparison never sees a *new* one.
`:since` matters: see [Pitfalls](#pitfalls-read-before-adding-a-debug_log-wait).

**Still connected right now? (liveness).** `Login accepted` proves a connection *happened*, not
that it's *still up*. For "is the device connected at this instant" the runner uses a **heartbeat**
instead: while connected the app logs a `battery`/`hist-*` row every ~10s, and those go silent when
the device is forgotten or drops. So the newest such row being recent (`logged_at` within ~30s of
now) means live. This is the one place `logged_at` beats `debug_log_id` -- it's a *recency* test,
not row ordering, so second-precision is fine. Helper: `device_appears_connected(db_path)`, used as
the runner's pre-checklist gate.

```sql
SELECT MAX(logged_at) FROM debug_log WHERE tag IN ('battery','hist-done','hist-start','hist-check','hist-result');
```

---

## Detecting whether the device is paired

The app writes its own `paired` setting -- `true` when a pairing succeeds, `false` only when the
user forgets the device (Forget Device, or the end of a confirmed factory reset), via
`AppDataStore.recordPaired` wired in `ApplicationDelegate`. So *paired-ness* is a definitive,
directly-queryable fact, not something to infer from login rows:

```sql
SELECT COALESCE((SELECT json_extract(setting_value, '$.paired') FROM setting WHERE setting_name='paired'), 0);
-- -> 1 = paired, 0 = not paired (or the setting is absent)
```

**This does not move when the device goes out of range or the app quits** -- pairing is durable, so
it stays `1` across a drop and across a restart. Don't read it as a connectivity check; for that use
`connection.connected` (or the login rows above):

```sql
SELECT COALESCE((SELECT json_extract(setting_value, '$.connected') FROM setting WHERE setting_name='connection'), 0);
-- -> 1 = connected right now, 0 = not
```

`00-test-setup.md` gates on the *paired* query -- if it reads `0` after switching to the test DB
(the "test DB + not paired" state a prior run's cleanup reset leaves), it scripts a re-pair; only
when paired does it confirm the live connection.

---

## Detecting history-fetch state (split tags)

`HistoryIngestor.refreshHistory()` logs one row per phase of a fetch, each under its **own**
tag so a check for one phase isn't clobbered by a later phase's row sharing a tag (a real bug
-- the trailing "complete" marker used to hide the "unchanged; DB refreshed" row under a single
`history` tag). The phases:

| tag | message | phase |
|---|---|---|
| `hist-start` | `history fetch triggered: trigger=… known_max=…` | fetch begins |
| `hist-check` | `history fetch: cheap check device_last_event=… known_max=…` | cheap single-frame read |
| `hist-result` | `…max_event_number=… unchanged; DB refreshed` / `…live entry ambiguous…` | outcome |
| `hist-done` | `history fetch complete: trigger=…` | logged on **every** exit path |
| `hist-gap` | `history gap recovered/explained/NOT recovered ev=…` | out-of-range backfill |

So each phase is a clean `tag='hist-…' ORDER BY debug_log_id DESC LIMIT 1` -- e.g. the forced
startup fetch completing (used by `00-test-setup.md`):

```sql
SELECT debug_log_id FROM debug_log
 WHERE tag = 'hist-done' AND message = 'history fetch complete: trigger=startup'
   AND debug_log_id > :since
 ORDER BY debug_log_id DESC LIMIT 1;
```

Other multi-domain tags are split the same way: `led-bright`/`led-blink`, and
`sync-auto`/`sync-dtap`/`sync-led` (startup device-sync checks). Single-domain tags
(`auto-pause`, `double-tap`, `battery`, …) are not split -- their rows can't clobber each other.

---

## Detecting that a factory reset confirmed

The app logs `Factory reset confirmed...` (tag `TimeFlip`) when the reset lands.

```sql
SELECT message FROM debug_log
 WHERE tag = 'TimeFlip' AND message LIKE 'Factory reset confirmed%' AND debug_log_id > :since
 ORDER BY debug_log_id DESC LIMIT 1;
```

Used by `reset_device_for_cleanup()`.

---

## Pitfalls (read before adding a `debug_log` wait)

`debug_log` **persists across app restarts**, and `debug_log_id` is **per file, not
global**. So:

- Capture a baseline `MAX(debug_log_id)` (`_latest_debug_log_id`) **before** the action
  you're waiting on, and scope the wait to `debug_log_id > since_id`. An unscoped query
  matches a stale pre-action row and returns instantly.

  ```sql
  SELECT MAX(debug_log_id) FROM debug_log;   -- capture as :since BEFORE the action
  ```

  **In a checklist step you don't do this by hand:** the supervisor refreshes
  `$current_log_id` to the live `MAX(debug_log_id)` before every step, so `debug_log_id >
  $current_log_id` already means "a row this step produced". It's same-step only, though --
  it advances each step. For a wait that must reach back across several steps, capture your own
  named baseline (`before_reset_id`, ...) at that earlier point. See README "current_log_id".

- Read that baseline from the **concrete file the switch will land on**, not through the
  `appdata.sqlite` symlink. On a prod->test switch, `test.sqlite`'s id sequence restarts at
  1, so a `since_id` from production's much larger sequence would never be exceeded (a false
  timeout). After a switch, pin the concrete path with `os.path.realpath(db_path)` and use
  `since_id=0`. `_sibling_db_path()` resolves a named sibling file directly. This is why
  `ensure_known_state()` returns the resolved concrete path and the whole run queries *that*,
  not the symlink.
