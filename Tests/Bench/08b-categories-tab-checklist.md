# Categories Tab Checklist

Covers the parts of the Categories tab that CI cannot reach: alerts actually appearing with the
right buttons, popovers opening, a field taking focus, Escape going to the field rather than the
window, controls disabled on a retired row, and the right-click rename.

**None of this needs the cube.** The tab is app state and database, so every scenario here would run
against a device sitting in a drawer. It is a Bench checklist because it drives the real window, not
because it drives the device -- and `Tests/Interactive/08i` is a stub for the same reason.

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

- [ ] Step 1: Query `db_type` and confirm it reads `{"type":"test"}`
```toml step
use = "method-24.a"
setting = "db_type"
expect = "{\"type\":\"test\"}"
```
- [ ] Step 2: Open Settings and switch to the Categories tab.
      Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10).
```toml step
[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Categories"
```
- [ ] Step 3: Confirm Active opens expanded and Inactive opens collapsed.
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
- [ ] Step 4: Confirm the two section labels read **Active** and **Inactive**.
      Not accessibility-readable, so this is the one look a person (or a screenshot) has to take.
      [Method: Number 17](../Methods.md#method-17).
```toml step
action = "ask_user"
prompt = "On the Categories tab, are the two collapsible sections labelled **Active** and **Inactive**?"
```

## Scenario A -- the create field appears, takes focus, and guards Save

**Preconditions:** Settings open on the Categories tab, from Setup above.

- [ ] Step 1: Click **Create** and confirm the field takes focus without being clicked.
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
- [ ] Step 2: Confirm **Save** is disabled for an empty field and for whitespace only.
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

- [ ] Step 1: Press Escape and confirm the window survives.
      This is the assertion the scenario exists for.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53

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
- [ ] Step 2: Confirm nothing was created and the field closed.
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
- [ ] Step 3: Confirm Escape closes the window once no field is open.
      The shortcut has to come back, or Escape stops working on the Settings window entirely.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53

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

**Preconditions:** Settings closed by Scenario B; this scenario reopens it. The rows are seeded
directly: the create control reads the database live rather than the loaded list, so a seeded row
reaches the alert without reopening the tab.

- [ ] Step 1: Seed one active `Email`, and reopen Settings on the Categories tab.
```toml step
[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, icon_id, colour_id, active) VALUES ('Email', 0, 0, 1);"

[[actions]]
use = "method-6"
item = "Settings..."

[[actions]]
use = "method-10"
tab = "Categories"
```
- [ ] Step 2: Type `Email` and Save; confirm the dead-end alert.
      An active category already holds the name, so there is nothing to decide and the alert offers
      no way to create anything: exactly one button, and it only dismisses.
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
- [ ] Step 3: Dismiss it, then retire that row and seed a second retired `Email`.
      Two retired namesakes and no active one is the ambiguous case.
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
action = "sql_exec"
query = "UPDATE category SET active = 0 WHERE category_name = 'Email';"

[[actions]]
action = "sql_exec"
query = "INSERT INTO category (category_name, icon_id, colour_id, active) VALUES ('Email', 0, 0, 0);"

[[actions]]
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE category_name = 'Email' AND active = 0;"
expect = "2"
```
- [ ] Step 4: Type `Email` again; confirm the ambiguous alert names both retired rows.
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
- [ ] Step 5: Confirm it offers create and cancel, and **no** reinstate.
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
- [ ] Step 6: Cancel, and confirm nothing was created.
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

## Scenario D -- reinstating is refused, and says so

The database allows one active category per name (`UN1_category`). A retired row whose name an
active one has taken since cannot come back under it, and the tab patches its loaded list rather
than re-reading -- so without the write reporting its refusal, the checkbox would tick over a row
that is still retired.

**Preconditions:** the two retired `Email` rows from Scenario C, Settings open.

- [ ] Step 1: Make one `Email` active again, then re-read the tab.
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
- [ ] Step 2: Expand the Inactive section.
      [Method: Number 15](../Methods.md#method-15). Addressed as `UI element 1`: System Events has no
      `disclosure triangle` class, so naming one that way is a syntax error, not an empty match.
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
expect_contains = "inactive_rows=1"
```
- [ ] Step 3: Tick the retired `Email` row's Active box; confirm the refusal alert.
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
- [ ] Step 4: Dismiss, then confirm the row is still retired and the box reads unticked.
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

- [ ] Step 1: Confirm the disabled and enabled controls on the retired row.
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

**Preconditions:** Settings open on the Categories tab with the active `Email` row in the Active
section, third after the seeded `Break` and `Meeting`.

- [ ] Step 1: Note the active `Email` row's colour and icon.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT colour_id FROM category WHERE category_name = 'Email' AND active = 1;"
capture = "email_colour_before"

[[actions]]
action = "sql_query"
query = "SELECT icon_id FROM category WHERE category_name = 'Email' AND active = 1;"
capture = "email_icon_before"
```
- [ ] Step 2: Open the colour swatch and pick a colour.
      An unset swatch draws as a hollow square with no fill, so its whole rectangle has to be
      clickable rather than just the 1pt stroke. If only the outline responds, this is where that
      shows up.
```toml step
action = "ask_user"
prompt = '''On the **Email** row in the Active section, click the colour swatch (Colour column):
1. Does a colour list pop over?
2. Pick any colour other than the one it already had. Does the popover close and the swatch take it?

Both true?'''
```
- [ ] Step 3: Confirm the colour reached the database.
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN colour_id != $email_colour_before THEN 'changed' ELSE 'unchanged' END FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "changed"
timeout_seconds = 30
```
- [ ] Step 4: Open the icon grid, confirm its shape, and pick an icon.
      42 seeded icons in a fixed 6-wide grid, so they land as an even 6x7 with no scrolling and no
      partial last row. There is no "none" cell, deliberately: clearing is re-clicking the
      selection.
```toml step
action = "ask_user"
prompt = '''On the same row, click the icon button (leftmost in the row):
1. Does a grid of icons pop over, **6 across**, with no scrolling?
2. Is there **no** blank/"none" cell?
3. Pick an icon. Does the popover close and the row show it?

All three true?'''
```
- [ ] Step 5: Confirm the icon reached the database.
```toml step
action = "wait_for_sql"
query = "SELECT CASE WHEN icon_id != $email_icon_before THEN 'changed' ELSE 'unchanged' END FROM category WHERE category_name = 'Email' AND active = 1;"
expect = "changed"
timeout_seconds = 30
```
- [ ] Step 6: Re-click the icon just chosen and confirm it clears to `icon_id` 0.
```toml step
[[actions]]
action = "ask_user"
prompt = "Open the icon grid again and click the **currently selected** icon (the highlighted one). Does the popover close and the row go back to showing no icon?"

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

**Preconditions:** Settings open on the Categories tab, the active `Email` row present.

- [ ] Step 1: Right-click the `Email` name, pick **Edit**, and confirm the field opens focused.
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
- [ ] Step 2: Press Escape and confirm the edit is abandoned outright.
      Escape exists so that opening Edit by mistake does not cost a round trip through a
      confirmation dialog: the field reverts and no alert appears.
```toml step
[[actions]]
action = "cgevent_key"
keycode = 53

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
- [ ] Step 3: Rename it and confirm the history warning.
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
- [ ] Step 4: Cancel and confirm the name is untouched.
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
- [ ] Step 5: Rename onto an active category's name; confirm the dead end.
      `Meeting` is seeded and active, so the name is simply taken -- the same dead end as when
      creating, with no rename-anyway offered.
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
- [ ] Step 6: Dismiss, then correct only the capitalisation and confirm it is **not** a collision.
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
- [ ] Step 7: Accept it and confirm the rename landed.
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
```

## Scenario H -- the daily limit commits like every other stepper

The arrows' behaviour is covered once, on auto-pause, in `05b`: every stepper in the window is one
control driving one hold loop. What is checked here is only that this row's field is wired to the
right category.

**Preconditions:** the active row, now called `EMAIL`, in the Active section.

- [ ] Step 1: Type a daily limit into the `EMAIL` row and commit with Return.
      [Method: Number 12](../Methods.md#method-12). It is the third row, so `text field 3`.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        set e to text field 3 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
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
- [ ] Step 2: Confirm no other category's limit moved.
      Each row's stepper carries its own hold key, keyed on the category id; a shared one would
      drive the wrong row.
```toml step
action = "sql_query"
query = "SELECT COUNT(*) FROM category WHERE daily_limit != 0 AND NOT (category_name = 'EMAIL' AND active = 1);"
expect = "0"
```

## Cleanup

- [ ] Step 1: Remove the categories this checklist created.
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
- [ ] Step 2: Close the Settings window.
      [Method: Number 23](../Methods.md#method-23).
```toml step
use = "method-23"
```
