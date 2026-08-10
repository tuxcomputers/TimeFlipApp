# Report Tab Checklist

### Last run - 2026-08-10 20:18 on the branch 'feature/singleInstance'

Covers the **Report** tab: a date range picked on two hand-drawn calendars, and what each category
took over it. The figures come from `AppDataStore.loadCategoryTotals(from:to:)`, which sums
`time_entry` with every span clipped to the range; the range itself comes from `ReportDateRange`,
whose day runs from `daily_reset_time` to the same time next day rather than midnight to midnight.

Requires a paired physical TimeFlip device and the app running with Developer Mode enabled and the
`debug` setting's `enabled` field `true`, same as every other checklist here.

**The fixture is three categories in three different states**, because the report's rule is that it
shows time, not that it shows *current* categories:

| Category | State | Seeded time |
| --- | --- | --- |
| `ZZ Assigned` | active, on a face | 5 days ago, 30 min 29 s |
| `ZZ NoFace` | active, on no face | 4 days ago, 45 min 30 s |
| `ZZ Retired` | **de**activated | 3 days ago, 60 min 31 s |

The last two are the ones worth having. A retired category must still report -- that is what
retiring promises (`docs/TODO-features-under-development.md`, Categories: *"Can still be reported
against, same as an active one"*), and it is the case a naive implementation gets wrong, because
`loadCategories()` and the Faces list both filter it out. A category on no face is the same question
from the other side: `loadCategoryTotals` joins `category` straight off `time_entry`, so neither the
face table nor the `active` flag has any say.

**The seeds sit 3 to 5 days ago, and each carries a category nothing else writes to.** Both matter.
Old dates keep them clear of anything the cube records while the suite runs, which all lands today;
private categories mean a real segment against `Break` or `Meeting` cannot join a total under test.
The database is **not** emptied first, and the device is **not** reset: neither is needed once the
categories are private, and both would cost more than they buy. Deleting `device_event` in
particular is actively harmful -- `latestRecordedEvent()` is the only record of the history position
(`HistoryIngestor`), an empty table reads as `nil`, and `nil` falls through to a full fetch from the
beginning, so the periodic fetch would repopulate the table within about ten seconds.

Durations of 30:29, 45:30 and 60:31 make every range asserted below a different figure, so no
assertion can pass against the wrong range. The seconds straddle the half-minute on purpose --
29 below it, 30 exactly on it, 31 above -- so Scenario D's seconds-off figures prove the value is
truncated to the minute rather than rounded. On round durations those assertions read the same
either way and proved nothing.

**The fixture is seeded by `Tests/00-test-setup.md` Step 9, not here**, and unconditionally rather
than only when this checklist was requested -- so every run starts from the same categories and the
Categories tab's row counts are a fixed baseline instead of depending on which checklists someone
asked for. `08b` accounts for the three extra rows explicitly; its notes say which number is the
seed's. It is seeded into the freshly-created `test.sqlite` **before the app is launched**, so the
synthetic `device_event` rows take the lowest ids and every real row lands after them -- seeded at
the end of setup they took the highest ids instead and became "the latest `device_event`", which
`01b` asserts is the open, growing one.

What this checklist does still do is **restore the three states** in Setup, because `08b` deactivates
every category but its own while testing the Active partition and does not put them back.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the test database and the device connected, both established by
`Tests/00-test-setup.md`, which the supervisor always runs first.

- [x] Step 1: Confirm `db_type` reads **test** before anything writes to it.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [x] Step 2: Capture the current day window's start epoch, derived from `daily_reset_time`.
The same boundary `ReportDateRange.dayStart` computes, so the seeded segments land inside the app's
days rather than inside calendar ones. (Note: the yesterday branch subtracts a flat 86400, exact only
where the local offset doesn't shift; Brisbane has no DST, and the steps below only use the today
branch.)
```toml step
action = "sql_query"
query = "WITH r AS (SELECT CAST(json_extract(setting_value,'$.hour') AS INT) h, CAST(json_extract(setting_value,'$.minute') AS INT) m FROM setting WHERE setting_name='daily_reset_time'), t AS (SELECT CAST(strftime('%s', date('now','localtime') || ' ' || substr('0'||h,-2) || ':' || substr('0'||m,-2) || ':00', 'utc') AS INT) AS today_reset FROM r) SELECT CASE WHEN CAST(strftime('%s','now') AS INT) >= today_reset THEN today_reset ELSE today_reset - 86400 END FROM t;"
capture = "window_start"
```
- [x] Step 3: Confirm this run can address the seeded days on the calendar at all.
The calendars are clicked by index ([Method: Number 28](../Methods.md#method-28)), and a calendar
shows six weeks starting from the week containing the 1st. Today's own cell therefore has to sit at
least 5 cells in for 5-days-ago to still be on the grid. That fails only in the first days of some
months, and failing here with a reason beats failing later on a click that silently did nothing.
```toml step
action = "sql_query"
query = "WITH f AS (SELECT date('now','localtime','start of month') AS first_day), g AS (SELECT date(first_day, '-' || ((CAST(strftime('%w', first_day) AS INT) + 6) % 7) || ' days') AS grid_start FROM f) SELECT CASE WHEN CAST(julianday(date('now','localtime')) - julianday(grid_start) AS INT) >= 5 THEN 'ok' ELSE 'today is only ' || CAST(julianday(date('now','localtime')) - julianday(grid_start) AS INT) || ' cells into the grid, so 5 days ago is not on it -- re-run later in the month' END FROM g;"
expect = "ok"
```
- [x] Step 4: Show seconds, so every assertion below is exact to the second.
The report follows this setting (`ReportView.formattedDuration`, the same format the menu bar uses).
At `H:MM` a wrong total could still round to a right-looking figure; at `H:MM:SS` it cannot.
(Note: written and read back as the JSON the app stores, `{"enabled":true}`. `loadDisplaySecondsEnabled`
reads the `enabled` field and falls back to `true` when it is missing, so a bare `true`/`false` here
is not a value the app can see -- and a raw read-back would confirm it anyway.)
```toml step
[[actions]]
use = "method-24.i"
setting = "display_seconds"
value = "{\"enabled\":true}"

[[actions]]
use = "method-24.f"
setting = "display_seconds"
field = "enabled"
expect = "1"
```
- [x] Step 5: Re-establish the fixture's three category states.
`Tests/00-test-setup.md` Step 9 seeds the rows and their states, but `08b` runs in between and
legitimately deactivates every category except its own (`UPDATE category SET active = 0 ... NOT
(category_name = 'Email' ...)`) as part of testing the Active partition, and never puts them back.
So by the time this checklist runs all three fixture categories are retired and the three states it
depends on are gone. Restoring them here rather than asking `08b` to tidy up after itself keeps each
checklist responsible for the state it needs -- and the seeded `time_entry` rows, which are what the
totals actually come from, are untouched by any of it.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_name IN ('ZZ Assigned', 'ZZ NoFace');"

[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 0 WHERE category_name = 'ZZ Retired';"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT category_id FROM category WHERE category_name = 'ZZ Assigned') WHERE face_id = 5;"

[[actions]]
action = "sql_query"
query = "SELECT (SELECT active FROM category WHERE category_name='ZZ Assigned') || (SELECT active FROM category WHERE category_name='ZZ NoFace') || (SELECT active FROM category WHERE category_name='ZZ Retired') || '/' || (SELECT COUNT(*) FROM face WHERE category_id = (SELECT category_id FROM category WHERE category_name='ZZ Assigned')) || '/' || (SELECT COUNT(*) FROM face WHERE category_id = (SELECT category_id FROM category WHERE category_name='ZZ NoFace'));"
expect = "110/1/0"
```
- [x] Step 6: Confirm the seeded time is present and intact.
The rows come from the shared setup, so this checklist starts by proving its fixture is really there
rather than discovering it is missing three assertions later.
```toml step
action = "sql_query"
query = "SELECT CAST(SUM(te.duration_seconds) AS INT) FROM time_entry te JOIN category c ON c.category_id = te.category_id WHERE c.category_name IN ('ZZ Assigned','ZZ NoFace','ZZ Retired');"
expect = "8190"
```
- [x] Step 7: Compute the calendar button indices for 5, 4 and 3 days ago.
Derived from the grid rather than hardcoded: cell `n` of the **From** calendar is button `3 + n`, and
`n` is the number of days from the start of the week containing the 1st ([Method: Number
28](../Methods.md#method-28)). The **To** calendar's cells start at button 47, so its index is the
same `n` plus 44.
```toml step
[[actions]]
action = "sql_query"
query = "WITH f AS (SELECT date('now','localtime','start of month') AS first_day), g AS (SELECT date(first_day, '-' || ((CAST(strftime('%w', first_day) AS INT) + 6) % 7) || ' days') AS grid_start FROM f) SELECT 3 + CAST(julianday(date('now','localtime','-5 days')) - julianday(grid_start) AS INT) FROM g;"
capture = "from_button_day5"

[[actions]]
action = "sql_query"
query = "WITH f AS (SELECT date('now','localtime','start of month') AS first_day), g AS (SELECT date(first_day, '-' || ((CAST(strftime('%w', first_day) AS INT) + 6) % 7) || ' days') AS grid_start FROM f) SELECT 3 + CAST(julianday(date('now','localtime','-4 days')) - julianday(grid_start) AS INT) FROM g;"
capture = "from_button_day4"

[[actions]]
action = "sql_query"
query = "WITH f AS (SELECT date('now','localtime','start of month') AS first_day), g AS (SELECT date(first_day, '-' || ((CAST(strftime('%w', first_day) AS INT) + 6) % 7) || ' days') AS grid_start FROM f) SELECT 47 + CAST(julianday(date('now','localtime','-3 days')) - julianday(grid_start) AS INT) FROM g;"
capture = "to_button_day3"
```

## Scenario A -- a start with no end reports that single day

**Preconditions:** Setup complete: the three categories seeded in their three states, seconds on.

- [x] Step 1: Open the Report tab and confirm it is the selected one.
Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10),
[Number 11](../Methods.md#method-11).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Report"

[[actions]]
use = "method-11"
tab = "Report"
expect = "1"
```
- [x] Step 2: Pick 5 days ago as the start, and confirm the calendar picked the date intended.
The click is by index, so this asserts where it actually landed rather than trusting Setup Step 9's
arithmetic. A disabled cell swallows a click silently, so without this a mis-computed index would
surface as a wrong total rather than as a wrong click.
[Method: Number 28](../Methods.md#method-28).
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button $from_button_day5 of group 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'From calendar picked%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "From calendar picked"
timeout_seconds = 15

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'From calendar picked%' ORDER BY debug_log_id DESC LIMIT 1) = 'From calendar picked ' || date('now','localtime','-5 days') THEN 'ok' ELSE 'clicked the wrong cell: ' || (SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'From calendar picked%' ORDER BY debug_log_id DESC LIMIT 1) END;"
expect = "ok"
```
- [x] Step 3: Confirm the report shows `ZZ Assigned` at **0:30:29** -- that day alone.
The end is untouched, so the range is the single day. Reading 2:15:00 here would mean an unset end
was being treated as "up to now"; reading nothing would mean the day boundary is wrong.
[Method: Number 28](../Methods.md#method-28).
```toml step
use = "method-28"
expect_contains = "ZZ Assigned|0:30:29|"
```
- [x] Step 4: Confirm the other two days are **not** in that single-day range.
The same read, asserted from the other direction: a start with no end must not reach forward.
```toml step
[[actions]]
use = "method-28"
capture = "single_day_totals"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$single_day_totals' LIKE '%ZZ NoFace%' OR '$single_day_totals' LIKE '%ZZ Retired%' THEN 'later days leaked into the single-day range: $single_day_totals' ELSE 'ok' END;"
expect = "ok"
```

## Scenario B -- a range spans days, and reports retired and unassigned categories alike

**Preconditions:** Scenario A complete, the start on 5 days ago.

- [x] Step 1: Set the end to 3 days ago, and confirm the pick landed there.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button $to_button_day3 of group 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'To calendar picked%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "To calendar picked"
timeout_seconds = 15

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN (SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'To calendar picked%' ORDER BY debug_log_id DESC LIMIT 1) = 'To calendar picked ' || date('now','localtime','-3 days') THEN 'ok' ELSE 'clicked the wrong cell: ' || (SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'To calendar picked%' ORDER BY debug_log_id DESC LIMIT 1) END;"
expect = "ok"
```
- [x] Step 2: Confirm the category still on a face reports **0:30:29**.
The ordinary case, and the control for the two below.
```toml step
use = "method-28"
expect_contains = "ZZ Assigned|0:30:29|"
```
- [x] Step 3: Confirm the category on **no face** reports **0:45:30**.
`loadCategoryTotals` joins `category` straight off `time_entry`, so the face table has no say. An
implementation that resolved the category through `face` would drop this row entirely.
```toml step
use = "method-28"
expect_contains = "ZZ NoFace|0:45:30|"
```
- [x] Step 4: Confirm the **deactivated** category reports **1:00:31**.
The assertion this fixture exists for. Retiring a category hides it from assignment and nothing else
-- it keeps its history and must keep reporting, which is what makes retiring safe to do. Both
`loadCategories()` and the Faces list filter `active = 0` out, so a report built on either would
silently lose this row and under-report the range.
```toml step
use = "method-28"
expect_contains = "ZZ Retired|1:00:31|"
```
- [x] Step 5: Confirm the range totals **2:15:00** across the three.
Derived from `time_entry` rather than read off the screen, so the figure the tab shows is compared
against the same table it claims to sum, over the same clipped window.
```toml step
action = "sql_query"
query = "WITH b AS (SELECT $window_start - 432000 AS f, $window_start - 259200 + 86400 AS t) SELECT CAST(SUM(min(de.start_epoch + te.duration_seconds, (SELECT t FROM b)) - max(de.start_epoch, (SELECT f FROM b))) AS INT) FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id JOIN category c ON c.category_id = te.category_id WHERE c.category_name IN ('ZZ Assigned','ZZ NoFace','ZZ Retired');"
expect = "8190"
```

## Scenario C -- moving the start forward drops the days it passes

**Preconditions:** Scenario B complete, the range covering 5 to 3 days ago.

- [x] Step 1: Move the start to 4 days ago and confirm `ZZ Assigned` leaves the report.
Proves the start bounds the range rather than the report simply totalling everything up to the end.
Its 30 minutes are now outside it, so the row goes entirely -- a category with nothing in the range
is left out, not listed as zero, which would read as "used, took no time".
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button $from_button_day4 of group 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'From calendar picked%' ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "From calendar picked"
timeout_seconds = 15

[[actions]]
use = "method-28"
capture = "narrowed_totals"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$narrowed_totals' LIKE '%ZZ Assigned%' THEN 'the dropped day is still being counted: $narrowed_totals' ELSE 'ok' END;"
expect = "ok"
```
- [x] Step 2: Confirm the two remaining categories are unchanged.
The narrowing must move the range's edge, not rescale what is inside it.
```toml step
[[actions]]
use = "method-28"
expect_contains = "ZZ NoFace|0:45:30|"

[[actions]]
use = "method-28"
expect_contains = "ZZ Retired|1:00:31|"
```

## Scenario D -- the format follows the menu bar's seconds setting

**Preconditions:** Scenario C complete, the range covering 4 and 3 days ago.

- [x] Step 1: Turn seconds off, relaunch, and reopen the Report tab.
The setting is read when the view draws, and a relaunch is the unambiguous way to be sure the new
value is the one in play. Methods: [Number 3](../Methods.md#method-3),
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4),
[Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
use = "method-24.i"
setting = "display_seconds"
value = "{\"enabled\":false}"

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Report"
```
- [x] Step 2: Pick 5 days ago again and confirm it reads **0:30** rather than 0:30:00.
A fresh launch opens on today with no end, and today holds none of the fixture, so a date has to be
picked again to have a figure to read at all.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button $from_button_day5 of group 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'From calendar picked%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "From calendar picked"
timeout_seconds = 15

[[actions]]
use = "method-28"
expect_contains = "ZZ Assigned|0:30|"
```
- [ ] Step 3: Extend the range to 3 days ago and confirm all three read as truncated minutes.
The case a single figure cannot make. The three seeds straddle the half-minute deliberately --
`0:30:29` below it, `0:45:30` exactly on it, `1:00:31` above -- so a formatter that rounded to the
nearest minute would report `0:30`, `0:46` and `1:01` here. Truncation is the rule
(`DurationFormat` takes `minutes` by integer division, so the seconds are dropped rather than
weighed), and the middle row is the one that proves it: exactly 30 seconds is where rounding and
truncation part company.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button $to_button_day3 of group 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT message FROM debug_log WHERE tag='report' AND message LIKE 'To calendar picked%' AND debug_log_id > $current_log_id ORDER BY debug_log_id DESC LIMIT 1;"
expect_contains = "To calendar picked"
timeout_seconds = 15

[[actions]]
use = "method-28"
expect_contains = "ZZ Assigned|0:30|"

[[actions]]
use = "method-28"
expect_contains = "ZZ NoFace|0:45|"

[[actions]]
use = "method-28"
expect_contains = "ZZ Retired|1:00|"
```

## Scenario E -- teardown, leaving nothing for the Interactive phase to inherit

**Preconditions:** Scenarios A to D complete. Runs even if any failed -- the seeded rows, the three
categories and face 5's reassignment are what would otherwise outlive this checklist.

- [x] Step 1: Close the Settings window and quit the app before unpicking the rows underneath it.
Methods: [Number 23](../Methods.md#method-23), [Number 3](../Methods.md#method-3).
```toml step
[[actions]]
use = "method-23"

[[actions]]
use = "method-3"
```
- [x] Step 2: Restore the seconds setting.
The seeded rows, the three categories and face 5 are **not** removed: they belong to
`Tests/00-test-setup.md`, which seeds them for every run and deliberately leaves them, since
`test.sqlite` is rebuilt from scratch next time and they are inert elsewhere -- their own categories,
and days old, so outside today's window entirely. Deleting them here would leave a resumed run
measuring a fixture that no longer exists.
```toml step
[[actions]]
use = "method-24.i"
setting = "display_seconds"
value = "{\"enabled\":true}"

[[actions]]
use = "method-24.f"
setting = "display_seconds"
field = "enabled"
expect = "1"
```
- [x] Step 3: Restart the app and leave the device unlocked and unpaused.
So the Interactive phase starts from the same clean state every other checklist assumes. Methods:
[Number 2](../Methods.md#method-2), [Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$current_log_id"
timeout_seconds = 60

[[actions]]
action = "ensure_unlocked_unpaused"
```
