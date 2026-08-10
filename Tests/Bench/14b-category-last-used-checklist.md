# Category Last Used Checklist

Covers the **Last used** column on the Categories tab: when a retired category last recorded time,
so two retired rows sharing a name can be told apart by the history behind them (see
`docs/TODO-features-under-development.md`, "Telling retired namesakes apart").

`Tests/TimeFlipAppTests/CategoryLastUsedTextTests.swift` pins the wording rules: nothing on an active
row, a date on a retired one, `Never` on a retired one with no history. What it cannot reach is the
query behind them. The date is `MAX(de.start_epoch + te.duration_seconds)` over a join
`loadCategories()` builds, and a unit test that fed the rule a `Date` would have agreed with itself
no matter which row that query picked.

So this measures the whole path: rows in the database, through the join, to the characters on screen.

**The fixture is two retired categories with entries on known, different days** -- `ZZ Lapsed Recent`
10 days back and `ZZ Lapsed Older` 20 days back, seeded by `Tests/00-test-setup.md` Step 9 as event
numbers `900004` and `900005`. Both dates are clear of the 3-to-5 days back the report fixture
occupies, so a wrong row cannot produce a right-looking answer, and they differ from each other so a
query returning MIN instead of MAX, or joining the wrong category, gives a visibly wrong day rather
than the same one twice.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the state `Tests/00-test-setup.md` leaves behind: test database, app running,
device paired and connected, and its Step 9 fixture seeded.

- [ ] Step 1: Confirm `db_type` reads **test**.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [ ] Step 2: Confirm the two seeded categories are retired and hold one entry each.
The premise. A missing or active fixture row would make every assertion below meaningless in a way
that reads as a UI bug.
```toml step
action = "sql_query"
query = "SELECT (SELECT COUNT(*) FROM category WHERE category_name IN ('ZZ Lapsed Recent','ZZ Lapsed Older') AND active = 0) || '/' || (SELECT COUNT(*) FROM time_entry te JOIN category c ON c.category_id = te.category_id WHERE c.category_name IN ('ZZ Lapsed Recent','ZZ Lapsed Older'));"
expect = "2/2"
```
- [ ] Step 3: Compute the two dates the screen must show, from the rows themselves.
Derived from the database rather than written in, so the assertion cannot drift from the fixture the
way a hardcoded date would every time the seed moves. `%-d` and `%-I` drop the leading zero and the `sed` lowercases AM/PM,
which is what `DateFormatter`'s `.medium` date and `.short` time styles produce. Confirmed against a
row already on screen: `ZZ Retired` rendered `7 Aug 2026 at 5:00 am`, and this command returns the
same string for it.
```toml step
[[actions]]
action = "shell"
command = "sqlite3 ~/Library/Application\\ Support/TimeFlip/appdata.sqlite \"SELECT CAST(MAX(de.start_epoch + te.duration_seconds) AS INT) FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id JOIN category c ON c.category_id = te.category_id WHERE c.category_name = 'ZZ Lapsed Recent';\" | xargs -I{} date -r {} '+%-d %b %Y at %-I:%M %p' | sed 's/ AM$/ am/; s/ PM$/ pm/'"
capture = "recent_expected"

[[actions]]
action = "shell"
command = "sqlite3 ~/Library/Application\\ Support/TimeFlip/appdata.sqlite \"SELECT CAST(MAX(de.start_epoch + te.duration_seconds) AS INT) FROM time_entry te JOIN device_event de ON de.device_event_id = te.device_event_id JOIN category c ON c.category_id = te.category_id WHERE c.category_name = 'ZZ Lapsed Older';\" | xargs -I{} date -r {} '+%-d %b %Y at %-I:%M %p' | sed 's/ AM$/ am/; s/ PM$/ pm/'"
capture = "older_expected"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$recent_expected' = '$older_expected' THEN 'both dates are the same, so no assertion below can tell the two rows apart' ELSE 'distinct' END;"
expect = "distinct"
```

## Scenario A -- a retired row shows when it last recorded time

**Preconditions:** Setup complete, both expected dates captured.

- [ ] Step 1: Open Settings on the Categories tab and expand the Inactive section.
Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10),
[Number 15](../Methods.md#method-15). The Inactive section opens collapsed
(`isInactiveExpanded = false`), so its rows do not exist in the accessibility tree until this runs.
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Categories"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click UI element 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.8
        return "inactive_rows=" & ((count of checkboxes of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "inactive_rows=4"
```
- [ ] Step 2: Confirm the Inactive list is captioned **Last used**.
The caption is on this section only: an active category is one being used now, so that column is
empty by definition in the Active list and a heading there would label nothing. Scenario B checks
the other half of that.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with i from 1 to (count of static texts)
                set out to out & (value of static text i) & "|"
            end repeat
            return out
        end tell
    end tell
end tell'''
expect_contains = "Last used|"
```
- [ ] Step 3: Confirm the **10 days back** row shows its own date.
The assertion the checklist exists for. Compared against the figure Setup derived from the rows, so
this fails if the query behind the column reads the wrong entry, the wrong category, or the start of
a segment rather than its end.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with i from 1 to (count of static texts)
                set out to out & (value of static text i) & "|"
            end repeat
            return out
        end tell
    end tell
end tell'''
expect_contains = "$recent_expected"
```
- [ ] Step 4: Confirm the **20 days back** row shows a different date, its own.
Two rows rather than one, because a column that reported the newest entry in the whole table, or the
same category twice, would satisfy Step 3 on its own.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with i from 1 to (count of static texts)
                set out to out & (value of static text i) & "|"
            end repeat
            return out
        end tell
    end tell
end tell'''
expect_contains = "$older_expected"
```

## Scenario B -- what the column does not say

**Preconditions:** Scenario A complete, Settings still open on the Categories tab with the Inactive
section expanded.

- [ ] Step 1: Confirm the Active list has no Last used caption and no dates.
The other half of the rule. `ZZ Assigned` is active and has an entry 5 days back, so a column that
drew for every category regardless of state would show a date here, and one that captioned every
section would show the heading.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with i from 1 to (count of static texts)
                set out to out & (value of static text i) & "|"
            end repeat
            return out
        end tell
    end tell
end tell'''
expect_contains = "Active|"
```
- [ ] Step 2: Confirm no date from the fixture appears anywhere in the Active list.
Named rather than inferred from the caption's absence: the heading and the cells are drawn by
different code, so one can be right while the other is wrong.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with i from 1 to (count of static texts)
                set out to out & (value of static text i) & "|"
            end repeat
            if out contains "$recent_expected" then return "a date leaked into the Active list"
            if out contains "$older_expected" then return "a date leaked into the Active list"
            if out contains "Last used" then return "the Active list is captioned Last used"
            return "clean"
        end tell
    end tell
end tell'''
expect_contains = "clean"
```
- [ ] Step 3: Close the Settings window.
Left open, it is inherited by whatever checklist runs next.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of window "TimeFlip Settings"
    end tell
end tell'''
```
