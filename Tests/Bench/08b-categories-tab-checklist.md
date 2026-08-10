# Categories Tab Checklist

### Last run - 2026-08-10 12:42 on the branch 'feature/manualMode'

Covers the parts of the Categories tab that CI cannot reach: alerts actually appearing with the
right buttons, popovers opening, a field taking focus, Escape going to the field rather than the
window, controls disabled on a retired row or by a locked face, the right-click rename, and the face
a retire clears.

**None of this needs the cube.** The tab is app state and database, so every scenario here would run
against a device sitting in a drawer. It is a Bench checklist because it drives the real window, not
because it drives the device. Only the *unlock* that lifts a locked face's bar on retiring is on the
Interactive side (`Tests/Interactive/08i`), because the lock control belongs to the face the cube is
resting on.

**Automated coverage, deliberately not repeated here:** every decision this tab makes is unit-tested
in `CategoryEditRulesTests` (which name collides with what, the icon toggle, the daily-limit clamp,
the Active partition), every write in `CategoryStoreTests`, and the whole create-to-reinstate
sequence in `Workflows/W09-category-lifecycle`. What is left is the presentation those tests cannot
see: an alert that decides correctly but never appears is a passing test and a broken app.

See `docs/TODO-categories-tab-tests.md` for the full split of what is covered where.

## The tab's accessibility shape

Read live on 2026-08-01; the steps below depend on it.

`scroll area 1 of group 1 of window "TimeFlip Settings"` holds three groups, one per `Section`:

| Group | Section |
|---|---|
| `group 1` | Active |
| `group 2` | the create control |
| `group 3` | Inactive |

An expanded section is a disclosure triangle, four column-header static texts, then **eight elements
per category row**, in this order: icon `button`, name `static text`, colour `button`, daily-limit
`text field`, `min` static text, two chevron `image`s, Active `checkbox`. So within a section, row
*k* is `checkbox k` / `text field k`, its icon is `button (2k-1)` and its colour swatch `button 2k`.

(Note: the **Active** and **Inactive** section titles are not exposed to accessibility at all -- a
collapsed section reports only its disclosure triangle. Confirming those labels needs an eye or a
screenshot, which is why Setup asks. The `Active` static text inside an expanded section is the
*column header*, not the section title.)

Alerts open as `sheet 1 of window "TimeFlip Settings"`. Their buttons' `title` is `missing value`;
the label is in `description` ([Method: Number 16](../Methods.md#method-16)).

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

The switch to the test database is done once by `Tests/00-test-setup.md`, which the supervisor
always runs first -- not repeated here.

- [x] Step 1: Query `db_type` and confirm it reads `{"type":"test"}`
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [x] Step 2: Open Settings and switch to the Categories tab.
      Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Categories"
```
- [x] Step 3: Confirm Active opens expanded and Inactive opens collapsed.
      The archive is folded away on purpose; the list you work in is not. Read from the disclosure
      triangles, whose value is the expanded state.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell scroll area 1 of group 1 of window "TimeFlip Settings"
            return "active=" & (value of UI element 1 of group 1 as string) & " inactive=" & (value of UI element 1 of group 3 as string)
        end tell
    end tell
end tell'''
expect_contains = "active=true inactive=false"
```
- [x] Step 4: Confirm the two section labels read **Active** and **Inactive**.
      Not accessibility-readable, so this is the one look a person (or a screenshot) has to take.
      [Method: Number 17](../Methods.md#method-17).
```toml step
action = "ask_user"
prompt = "On the Categories tab, are the two collapsible sections labelled **Active** and **Inactive**?"
```

## Scenario A -- the create field appears, takes focus, and guards Save

**Preconditions:** Settings open on the Categories tab, from Setup above.

- [x] Step 1: Click **Create** and confirm the field takes focus without being clicked.
      Focus is set a runloop turn after the field appears, since at `onAppear` it is not yet in the
      window's responder chain and a synchronous focus is dropped. Typing straight after Create is
      the whole point of the deferral, so this is the step that proves it still works.
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.8
        return "focused=" & (focused of text field 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings" as string)
    end tell
end tell'''
expect_contains = "focused=true"
```
- [x] Step 2: Confirm **Save** is disabled for an empty field and for whitespace only.
      A name that normalises to nothing must not be savable. `button 1 of group 2` is Create before
      the field opens and Save after it.
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set b to button 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set wasEmpty to (enabled of b) as string
        keystroke "   "
        delay 0.4
        set wasBlank to (enabled of b) as string
        keystroke "a" using command down
        keystroke "Discovery category"
        delay 0.4
        return "empty=" & wasEmpty & " blank=" & wasBlank & " named=" & ((enabled of b) as string)
    end tell
end tell'''
expect_contains = "empty=false blank=false named=true"
```

## Scenario B -- Escape cancels the field, not the window

Covers `AppState.openCategoryNameFields`: while a name is being typed the window's Close button
gives up its Escape shortcut, because a key equivalent is dispatched before the focused field sees
the key and the field could not otherwise win. Getting this wrong closes the whole Settings window
on a keystroke meant to abandon one field.

**Preconditions:** the create field open and holding a name, from Scenario A.

- [x] Step 1: Press Escape and confirm the window survives.
      This is the assertion the scenario exists for.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "window=" & ((exists window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "window=true"
```
- [x] Step 2: Confirm nothing was created and the field closed.
      The create control is back to a lone button, which is how the collapsed state reads.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Discovery category';"
expect = "0"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return "fields=" & ((count of text fields) as string) & " buttons=" & ((count of buttons) as string)
        end tell
    end tell
end tell'''
expect_contains = "fields=0 buttons=1"
```
- [x] Step 3: Confirm Escape closes the window once no field is open.
      The shortcut has to come back, or Escape stops working on the Settings window entirely.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "window=" & ((exists window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "window=false"
```

## Scenario C -- the three collision alerts, each with its own buttons

The decision behind each is unit-tested. What is checked here is that the alert reaches the screen
and offers exactly the choices it should -- in particular that the ambiguous case offers **no**
reinstate, since the whole point is that it must not pick one for the user.

**Preconditions:** Settings closed by Scenario B; this scenario reopens it. The active row is made
**through the Create control**, so the list on screen and the database agree from the start. Only the
second, retired row is seeded, because no UI can create one: a retired category has to be created and
then retired, and this scenario needs it retired before the create control is used again.

- [x] Step 1: Reopen Settings on the Categories tab and create `Email` from the **Create button**.
      Every `Email` an earlier attempt left is dropped first, so the scenario is idempotent. That
      cleanup is the one piece of SQL here, and it is a delete rather than a seed: a leftover active
      namesake would send the create straight to the dead-end alert of Step 2, so no row would be
      created and the failure would land a step later than its cause. Resuming produces exactly that,
      since it keeps the existing `test.sqlite` rather than rebuilding it, leftover rows and all
      (measured on 2026-08-08, resuming into this scenario after a halted run). The faces are cleared
      first so no foreign key is left pointing at a deleted row.
      **Creating it rather than seeding it is what makes the rest of the scenario addressable.** The
      create path re-reads the list on success (`onCreated` -> `loadCategories()`), so the new row is
      on screen as well as in the database; a seeded row is only in the database, and Step 3 has to
      find it by name among the rendered rows.
      **The pass is the database record.** The window is not asserted on at all here -- the sheet
      count comes back only so a stray alert is in the transcript -- and `wait_for_sql` confirming
      exactly one active `Email` is what the step turns on. That way a control that did not take the
      name fails here, rather than passing and leaving a later step to report a row that was never
      created.
      Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'Email');"

[[actions]]
action = "sql_exec"
query = "DELETE FROM time_entry WHERE category_id IN (SELECT category_id FROM category WHERE category_name = 'Email');"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'Email';"

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
        click button 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.6
        keystroke "Email"
        keystroke return
        delay 1.2
        return "sheets=" & ((count of sheets of window "TimeFlip Settings") as string)
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "1"
timeout_seconds = 10
```
- [x] Step 2: Try to create a **second** `Email`; confirm the dead-end alert.
      The same control, the same name, one step later: an active category now holds it, so there is
      nothing to decide and the alert offers no way to create anything -- exactly one button, and it
      only dismisses. Step 1 passing and this one passing are the two halves of the same control,
      which is why they read identically apart from what they assert.
      (Note: the row it collides with was created through this control in Step 1, so it is on screen
      under **Active** while the alert is up. Step 3 is where the database and the window start to
      disagree, and where the tab switch that reconciles them lives.)
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.6
        keystroke "Email"
        keystroke return
        delay 1.2
        tell sheet 1 of window "TimeFlip Settings"
            return "title=" & (value of static text 1 as string) & " | buttons=" & ((count of buttons) as string)
        end tell
    end tell
end tell'''
expect_contains = "title=That category already exists | buttons=1"
```
- [x] Step 3: Dismiss it, retire that row **from its Active checkbox**, seed a second retired
      `Email`, and re-read the tab.
      Two retired namesakes and no active one is the ambiguous case.
      Retiring through the control rather than an `UPDATE` is the point of doing it here: it is the
      path a user takes, it proves the checkbox actually writes, and it keeps the window honest by
      itself -- an edit made in the UI patches the loaded record in place, so the row moves from
      Active to Inactive as it is clicked (`CategoryEditRules.patching`). A SQL update behind the
      window changes the database and leaves the list showing the old state.
      **The row is addressed by index**, which is unavoidable: a row's checkbox is not reachable
      from its name, only from its position (see the accessibility shape above). The index is
      counted **off the screen**, not derived from a query, and that is deliberate.
      `loadCategories()` returns `results.sorted(by: CategoryRecord.displayOrder)`, and that
      comparator cannot be reproduced in SQL: names that are entirely a number come first in numeric
      order (so 1, 2, 10, not 1, 10, 2), the rest fall back to `localizedStandardCompare` -- the
      Finder ordering that puts `ABC-2` before `ABC-10` -- and ties break on `category_id`. SQLite
      has no equivalent of that middle rule, so any `ORDER BY` here would be an approximation that
      agrees with the app until it quietly doesn't, and the failure would be a click on the wrong
      row. Walking the rendered names asks the list where `Email` actually is, and stays right when
      the fixture gains a category or the comparator changes. The step fails loudly if it is not
      found, and the assertion after the click names `Email` specifically, so a miscount cannot
      quietly retire somebody else.
      The tab switch at the end is for the *seeded* row, which no UI can create: a retired category
      has no create control. Without it the window would show one retired `Email` where the database
      has two, and Step 4's alert would name a row nothing on screen accounts for. The alert itself
      never needed it -- `findCategories` queries the database live on every Save.
      Methods: [Number 13](../Methods.md#method-13), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of sheet 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE active = 1 AND category_id >= 1;"
capture = "active_before_retire"

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set labels to value of every static text
            set rowIndex to 0
            repeat with i from 5 to (count of labels) by 2
                set rowIndex to rowIndex + 1
                if item i of labels is "Email" then
                    click checkbox rowIndex
                    return "clicked row " & rowIndex
                end if
            end repeat
        end tell
        return "Email is not in the Active list"
    end tell
end tell'''
expect_contains = "clicked row"

[[actions]]
action = "wait_for_sql"
query = "SELECT (SELECT active FROM category WHERE category_name = 'Email') || '/' || ((SELECT COUNT(*) FROM category WHERE active = 1 AND category_id >= 1) - $active_before_retire);"
expect = "0/-1"
timeout_seconds = 10

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, icon_id, colour_id, active) VALUES ('Email', 0, 0, 0);"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Email' AND active = 0;"
expect = "2"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"
```
### Bugs found and fixed - branch 'feature/manualMode'
2026-08-09 - This step could not find `Email` among the rendered rows: Step 1 seeded it with SQL and
reopening Settings did not re-read the list, so the row existed only in the database. Step 1 now
creates it from the Create control, whose success path re-reads the list, and passes on the database
record rather than on anything the window says.
- [x] Step 4: Type `Email` again; confirm the ambiguous alert names both retired rows.
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 0.6
        keystroke "Email"
        keystroke return
        delay 1.2
        tell sheet 1 of window "TimeFlip Settings"
            return "msg=" & (value of static text 2 as string)
        end tell
    end tell
end tell'''
expect_contains = "2 inactive categories are called"
```
- [x] Step 5: Confirm it offers create and cancel, and **no** reinstate.
      The absent third button is the assertion: offering to bring one back would mean picking blind.
      Creating is still allowed, since only an *active* namesake bars that.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell sheet 1 of window "TimeFlip Settings"
            set labels to ""
            repeat with b in buttons
                set labels to labels & "[" & (description of b as string) & "]"
            end repeat
            return "count=" & ((count of buttons) as string) & " " & labels
        end tell
    end tell
end tell'''
expect_contains = "count=2 [Create a new category with the same name][Cancel]"
```
- [x] Step 6: Cancel, and confirm nothing was created.
      (Note: Cancel here deliberately leaves the **create field still open**, holding the typed
      name, so the name can be reconsidered rather than retyped. Only the active-collision alert
      closes the field, because there the name is unusable and there is nothing to reconsider. A
      tab switch tears the field's view down but leaves `isCreating` set, so it reappears on
      returning -- see `CategoryCreateControl`.)
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of sheet 1 of window "TimeFlip Settings" whose description is "Cancel")
    end tell
end tell'''

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Email';"
expect = "2"
```
- [x] Step 7: Escape out of the create field it left open.
      Not tidying for its own sake: an open create field owns Escape (`openCategoryNameFields`), so
      leaving it open would have Scenario G's Escape abandon *this* field instead of the rename it
      is aimed at, and the later scenarios would run with a half-open form on screen.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 2 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return "fields=" & ((count of text fields) as string) & " buttons=" & ((count of buttons) as string)
        end tell
    end tell
end tell'''
expect_contains = "fields=0 buttons=1"
```

## Scenario D -- reinstating is refused, and says so

The database allows one active category per name (`UN1_category`). A retired row whose name an
active one has taken since cannot come back under it, and the tab patches its loaded list rather
than re-reading -- so without the write reporting its refusal, the checkbox would tick over a row
that is still retired.

**Preconditions:** the two retired `Email` rows from Scenario C, Settings open.

- [x] Step 1: Make one `Email` active again, then re-read the tab.
      Switching away and back re-runs the list's `onAppear`, which is what puts the seeded rows on
      screen.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_id = (SELECT MIN(category_id) FROM category WHERE category_name = 'Email');"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"
```
- [x] Step 2: Expand the Inactive section.
      [Method: Number 15](../Methods.md#method-15). Addressed as `UI element 1`: System Events has no
      `disclosure triangle` class, so naming one that way is a syntax error, not an empty match.
      (Note: the count includes `ZZ Retired`, one of the three categories `Tests/00-test-setup.md`
      Step 8 seeds for the report checklist. That fixture is seeded on every run rather than only
      when the report checklist was requested, precisely so this number is a fixed baseline instead
      of depending on which checklists someone asked for. The retired row this step is really about
      is `Email`; if the seed's shape ever changes, this is the number that moves with it.)
```toml step
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
expect_contains = "inactive_rows=2"
```
- [x] Step 3: Tick the retired `Email` row's Active box; confirm the refusal alert.
```toml step
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click checkbox 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 1.5
        tell sheet 1 of window "TimeFlip Settings"
            return "title=" & (value of static text 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "title=That name is already in use"
```
- [x] Step 4: Dismiss, then confirm the row is still retired and the box reads unticked.
      Both halves matter: the database must not have changed, and the UI must not claim it did.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of sheet 1 of window "TimeFlip Settings" whose description is "OK")
        delay 0.8
        return "checkbox=" & (value of checkbox 1 of group 3 of scroll area 1 of group 1 of window "TimeFlip Settings" as string)
    end tell
end tell'''
expect_contains = "checkbox=0"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Email' AND active = 0;"
expect = "1"
```

## Scenario E -- a retired row is read-only except for its Active box

A retired category is a record of what it was, not a setting worth tuning, so its colour, icon and
daily limit are disabled. The Active box stays live, since reinstating is the one edit an inactive
row must still allow.

**Preconditions:** the Inactive section expanded, showing one retired `Email`.

- [x] Step 1: Confirm the disabled and enabled controls on the retired row.
      Icon and colour are `button 1` and `button 2` of the row, the limit is `text field 1`, and the
      Active box is `checkbox 1`.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 3 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return "icon=" & (enabled of button 1 as string) & " colour=" & (enabled of button 2 as string) & " limit=" & (enabled of text field 1 as string) & " active=" & (enabled of checkbox 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "icon=false colour=false limit=false active=true"
```

## Scenario F -- the colour and icon popovers

Neither can be reached from a test: both are `.popover` presentations, and the icon grid's
clear-by-re-clicking has no other trigger.

Named values, not "pick anything". A step that accepts whatever the tester happened to click can
only assert *that something changed*, which passes just as happily when the popover wrote the wrong
row or the wrong field. Asking for **Red** and **UX** specifically means the assertion is the value
itself, so a mis-wired picker fails here instead of looking fine.

Every other category is retired first, leaving the Active section holding **one row**. That removes
the "which row did you click" ambiguity from a step a human drives, and makes the row addressable as
row 1 rather than by counting seeds.

**Faces 2 and 8 are unlocked before that retire, and the order matters.** They hold `Break` and
`Meeting`, and the app **refuses** to deactivate a category a locked face holds -- Scenario I asserts
that refusal, and the message it checks tells the user to unlock the face first. Retiring them with a
bare `UPDATE` would manufacture a state the app forbids, in the same file that tests the rule; going
through the unlock is the app's own prescribed route, so every state here is one it could have
produced. Clearing the faces afterwards is the other half: retiring through the app puts every face
holding that category back on `Unassigned`, so the SQL has to do that too, or the faces are left
pointing at retired categories. Scenario I puts both locks back when it rebuilds the seeds.

**Preconditions:** Settings open on the Categories tab, the active `Email` row present.

- [x] Step 1: Retire every category except the active `Email`, and re-read the tab.
      Switching away and back re-runs the list's `onAppear`. Cleanup puts the seeded ones back.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE face SET locked = 0 WHERE face_id IN (2, 8);"

[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 0 WHERE category_id >= 1 AND NOT (category_name = 'Email' AND active = 1);"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE category_id IN (SELECT category_id FROM category WHERE active = 0);"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "active_rows=" & ((count of checkboxes of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "active_rows=1"
```
- [x] Step 2: Clear the row's colour and icon so the picks below are unambiguous.
      Starting from `None` for both means a passing assertion cannot be the value that was already
      there.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET colour_id = 0, icon_id = 0 WHERE category_name = 'Email' AND active = 1;"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"
```
- [x] Step 3: Open the colour swatch and pick **Red**.
      An unset swatch draws as a hollow square with no fill, so its whole rectangle has to be
      clickable rather than just the 1pt stroke. If only the outline responds, this is where that
      shows up. It is the only row on screen.
```toml step
action = "ask_user"
prompt = '''On the **Email** row (the only row in the Active section), click the colour swatch in the Colour column:
1. Does a colour list pop over?
2. Pick **Red**. Does the popover close and the swatch turn red?

Both true?'''
```
- [x] Step 4: Confirm the database holds **Red**, not merely a change.
      `colour_id` 1 is `Red` (`database/005_colour.sql`). Any other colour fails this step: it means
      the popover wrote something other than what was clicked.
```toml step
action = "wait_for_sql"
query = "SELECT colour_id FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "1"
timeout_seconds = 30
```
- [x] Step 5: Open the icon grid, confirm its shape, and pick the **UX** icon.
      42 seeded icons in a fixed 6-wide grid, so they land as an even 6x7 with no scrolling and no
      partial last row. There is no "none" cell, deliberately: clearing is re-clicking the
      selection. Each cell carries its name as a tooltip, which is how to find UX among 42.
```toml step
action = "ask_user"
prompt = '''On the same row, click the icon button (leftmost in the row):
1. Does a grid of icons pop over, **6 across**, with no scrolling?
2. Is there **no** blank/"none" cell?
3. Pick the **UX** icon (hover a cell to see its name). Does the popover close and the row show it?

All three true?'''
```
- [x] Step 6: Confirm the database holds the **UX** icon.
      `icon_id` 40 is `ic_ux` (`database/004_icon.sql`). As with the colour, the value is the
      assertion: a grid that wrote the cell next to the one clicked would pass a "did it change"
      check and fail this one.
```toml step
action = "wait_for_sql"
query = "SELECT icon_id FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "40"
timeout_seconds = 30
```
- [x] Step 7: Re-click the UX icon and confirm it clears to `icon_id` 0.
      Re-clicking the selection is the only way to unset an icon, since the grid has no none cell.
```toml step
[[actions]]
action = "ask_user"
prompt = "Open the icon grid again and click the **UX** icon a second time (it will be the highlighted one). Does the popover close and the row go back to showing no icon?"

[[actions]]
action = "wait_for_sql"
query = "SELECT icon_id FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "0"
timeout_seconds = 30
```

## Scenario G -- renaming through the right-click menu

The menu is **invisible to accessibility**: the name element advertises an `AXShowMenu` action that
performs without error and opens nothing, and after a real right-click `count of menus` still
reports 0 on both the element and the process. It is genuinely on screen, confirmed by screenshot on
2026-08-01, so it is driven by coordinate instead --
[Method: Number 26](../Methods.md#method-26).

**Preconditions:** Settings open on the Categories tab, the active `Email` row present, and `Email`
the only active category -- Scenario F retired the rest.

That last part is why Step 5 reactivates `Meeting` before renaming onto it: a dead-end collision
needs an **active** namesake, and Scenario F had left none. Step 7 retires it again, so Scenario H
inherits the single-row Active section it expects.

- [x] Step 1: Right-click the `Email` name, pick **Edit**, and confirm the field opens focused.
      Right-clicked near the right-hand end of the name column, the part a short label does not
      cover -- the hit area `contentShape(Rectangle())` exists to claim. The field replaces the name
      `static text`, so it becomes `text field 1` of the section, pre-filled with the current name.
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "first static text of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\" whose value is \"Email\""

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return "value=" & (value of text field 1 as string) & " focused=" & (focused of text field 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "value=Email focused=true"
```
- [x] Step 2: Press Escape and confirm the edit is abandoned outright.
      Escape exists so that opening Edit by mistake does not cost a round trip through a
      confirmation dialog: the field reverts and no alert appears.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53
activate = "TimeFlip"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "sheets=" & ((count of sheets of window "TimeFlip Settings") as string) & " name=" & ((exists (first static text of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings" whose value is "Email")) as string)
    end tell
end tell'''
expect_contains = "sheets=0 name=true"
```
- [x] Step 3: Rename it and confirm the history warning.
      The name does not change until this is accepted. The warning is about history: everything
      links by `category_id`, so reports covering time *before* the rename show the new name too.
```toml step
[[actions]]
action = "cgevent_context_menu_pick"
element = "first static text of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\" whose value is \"Email\""

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        delay 0.3
        keystroke "a" using command down
        keystroke "Client work"
        keystroke return
        delay 1.2
        tell sheet 1 of window "TimeFlip Settings"
            return "title=" & (value of static text 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "title=Rename this category?"
```
- [x] Step 4: Cancel and confirm the name is untouched.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of sheet 1 of window "TimeFlip Settings" whose description is "Cancel")
    end tell
end tell'''

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Client work';"
expect = "0"
```
- [x] Step 5: Reactivate `Meeting`, then rename onto it; confirm the dead end.
      A name held by an **active** category is simply taken -- the same dead end as when creating,
      with no rename-anyway offered. `Meeting` has to be brought back first, because Scenario F
      retired it along with everything else: against a *retired* namesake this raises the
      inactive-collision alert instead, which offers "Rename anyway" and lets the rename through.
      That is exactly what happened on 2026-08-01, and the row ended up genuinely renamed to
      `Meeting`.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_id = (SELECT MIN(category_id) FROM category WHERE category_name = 'Meeting');"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"

[[actions]]
action = "cgevent_context_menu_pick"
element = "first static text of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\" whose value is \"Email\""

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        delay 0.3
        keystroke "a" using command down
        keystroke "Meeting"
        keystroke return
        delay 1.2
        tell sheet 1 of window "TimeFlip Settings"
            return "title=" & (value of static text 1 as string) & " buttons=" & ((count of buttons) as string)
        end tell
    end tell
end tell'''
expect_contains = "title=That category already exists buttons=1"
```
- [x] Step 6: Dismiss, then correct only the capitalisation and confirm it is **not** a collision.
      The lookup is `COLLATE NOCASE`, so the row finds itself. Only the id comparison stops the app
      refusing a name the row already holds, and this is the only place that check meets a real
      window.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click button 1 of sheet 1 of window "TimeFlip Settings"
    end tell
end tell'''

[[actions]]
action = "cgevent_context_menu_pick"
element = "first static text of group 1 of scroll area 1 of group 1 of window \"TimeFlip Settings\" whose value is \"Email\""

[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        delay 0.3
        keystroke "a" using command down
        keystroke "EMAIL"
        keystroke return
        delay 1.2
        tell sheet 1 of window "TimeFlip Settings"
            return "title=" & (value of static text 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "title=Rename this category?"
```
- [x] Step 7: Accept it and confirm the rename landed.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        click (first button of sheet 1 of window "TimeFlip Settings" whose description is "OK")
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'EMAIL' AND active = 1;"
expect = "1"
timeout_seconds = 30

[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 0 WHERE category_name = 'Meeting';"

[[actions]]
use = "method-10"
tab = "Device"

[[actions]]
use = "method-10"
tab = "Categories"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "active_rows=" & ((count of checkboxes of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "active_rows=1"
```

## Scenario H -- the daily limit commits like every other stepper

The arrows' behaviour is covered once, on auto-pause, in `05b`: every stepper in the window is one
control driving one hold loop. What is checked here is only that this row's field is wired to the
right category.

**Preconditions:** the active row, now called `EMAIL`, in the Active section.

- [x] Step 1: Type a daily limit into the `EMAIL` row and commit with Return.
      [Method: Number 12](../Methods.md#method-12). Scenario F left it the only active row, so
      `text field 1`.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 1 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
        set focused of e to true
        keystroke "a" using command down
        keystroke "90"
        keystroke return
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT daily_limit FROM category WHERE category_name = 'EMAIL' AND active = 1;"
expect = "90"
timeout_seconds = 30
```
- [x] Step 2: Confirm no other category's limit moved.
      Each row's stepper carries its own hold key, keyed on the category id; a shared one would
      drive the wrong row.
```toml step
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE daily_limit != 0 AND NOT (category_name = 'EMAIL' AND active = 1);"
expect = "0"
```

## Scenario I -- retiring clears the face, and a locked face bars it

Retiring takes the category off every face holding it, so no face is left drawing one that has
stopped being offered anywhere. A **locked** face bars the retire instead of being cleared by it:
that face has been told to keep what it has, and the Active box is disabled rather than the app
picking which of the two instructions wins.

Both halves are reachable with the cube in a drawer, because the seed locks faces 2 (`Meeting`) and
8 (`Break`): two categories that cannot be retired, sitting beside one that can.

**Preconditions:** Settings open on the Categories tab. Step 1 rebuilds the rows the steps below
address, since the scenarios before this leave the list in a state of their own.

- [x] Step 1: Seed one category on an unlocked face, put the seeds back on their locked ones, and
      restart the app.
      The restart is the point: face and lock state are read at launch and refreshed only by the
      app's own writes, so SQL alone leaves the window disagreeing with the database. Methods:
      [Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
      [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = CASE WHEN category_name IN ('Break','Meeting') THEN 1 ELSE 0 END WHERE category_id >= 1;"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, active) SELECT 'Face test', 1 WHERE NOT EXISTS (SELECT 1 FROM category WHERE category_name = 'Face test');"

[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_name = 'Face test';"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT MIN(category_id) FROM category WHERE category_name = 'Meeting' AND active = 1), locked = 1 WHERE face_id = 2;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT MIN(category_id) FROM category WHERE category_name = 'Break' AND active = 1), locked = 1 WHERE face_id = 8;"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT category_id FROM category WHERE category_name = 'Face test'), locked = 0 WHERE face_id = 3;"

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Categories"
```
- [x] Step 2: Confirm the Active box is dead on the two locked-face rows and live on the third.
      Names as well as states, because the whole claim is which row is which: the section holds
      `Break`, `Face test`, `Meeting` in that order, and row *k*'s name is `static text (2k + 3)`
      after the four column headers.
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            set out to ""
            repeat with k from 1 to 3
                set out to out & (value of static text (2 * k + 3)) & "=" & (enabled of checkbox k as string) & " "
            end repeat
            return out
        end tell
    end tell
end tell'''
expect_contains = "Break=false Face test=true Meeting=false"
```
- [x] Step 3: Confirm the disabled box explains itself, naming the face in the way.
      The row gives no clue which face it is, and a dead control with no reason is the failure this
      tooltip exists to prevent. Read as `AXHelp` rather than by hovering: the help tag lands on the
      checkbox itself even though `.help` is applied to the container around it, so the text is
      assertable without a mouse. (A synthetic `kCGEventMouseMoved` onto the control does **not**
      raise the visible tag -- AppKit wants real tracking-area movement -- so a hover-and-screenshot
      version of this step would fail on something that works. That the tag does render for a real
      pointer was confirmed by eye on 2026-08-06.)
```toml step
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return help of checkbox 1 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
    end tell
end tell'''
expect = "Face 8 is locked to this category. Unlock it on the Faces tab to deactivate this category."
```
- [x] Step 4: Retire `Face test` from its Active box; confirm the face it was on is back on
      `Unassigned`.
      The database is the assertion, not the row moving: `face.category_id` 0 is the `Unassigned`
      sentinel every unassigned face points at.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click checkbox 2 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 1.5
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT active FROM category WHERE category_name = 'Face test';"
expect = "0"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT category_id FROM face WHERE face_id = 3;"
expect = "0"
```
- [x] Step 5: Confirm the clear was reported, naming the face it touched.
      [Method: Number 24.d](../Methods.md#method-24), the `face-clear` tag.
```toml step
use = "method-24.d"
tag = "face-clear"
expect_contains = "face 3 back to Unassigned"
```
- [x] Step 6: Confirm the two locked-face rows are all that is left in the Active section.
      The retired row moved to Inactive, and neither category on a locked face went with it. The
      report fixture's categories are not in this count: Scenario F retires every non-`Email`
      category, the seeded ones included, and nothing reinstates them.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        return "active_rows=" & ((count of checkboxes of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings") as string)
    end tell
end tell'''
expect_contains = "active_rows=2"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name IN ('Break','Meeting') AND active = 1;"
expect = "2"
```
The refusal the disabled box stands in for has no step here, and cannot have one: the UI will not
raise it (that is what the disabling is), and `sql_exec` bypasses the app entirely. It is covered in
`CategoryStoreTests`, and the unlock that lifts it is `Tests/Interactive/08i`, which needs the cube
on the locked face to reach the Faces tab's lock control.

## Cleanup

- [x] Step 1: Put face 3 back on `Unassigned` and drop the category Scenario I put there.
      A face still pointing at the row would make the delete below fail on the foreign key rather
      than leaving anything behind.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = 0 WHERE face_id = 3;"

[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name = 'Face test';"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Face test';"
expect = "0"
```
- [x] Step 2: Remove the categories this checklist created.
      They exist only to make the alerts reachable, and leaving them behind would change what the
      next run of Scenario C sees.
```toml step
[[actions]]
action = "sql_exec"
query = "DELETE FROM category WHERE category_name IN ('Email','EMAIL','Client work','Discovery category');"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name IN ('Email','EMAIL','Client work','Discovery category');"
expect = "0"
```
- [x] Step 3: Reinstate the seeded categories Scenario F retired.
      `Break` and `Meeting` are the two faces the physical cube carries stickers for, so the whole
      Interactive phase that follows expects them active. Leaving them retired would be this
      checklist quietly changing the ones after it.
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_id IN (SELECT MIN(category_id) FROM category WHERE category_name IN ('Break','Meeting') GROUP BY category_name COLLATE NOCASE);"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name IN ('Break','Meeting') AND active = 1;"
expect = "2"
```
- [x] Step 4: Close the Settings window.
      [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
