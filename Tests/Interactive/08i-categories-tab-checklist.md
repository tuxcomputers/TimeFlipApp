# Categories Tab Checklist

### Last run - 2026-08-10 20:25 on the branch 'feature/singleInstance'

One scenario, and only because of where the lock control lives.

Everything else about the tab is scriptable and lives in `Tests/Bench/08b`. The one thing that
looked like it needed a person -- the **right-click context menu** that opens the inline rename --
turned out to be scriptable too. That took proving, because the menu is invisible to accessibility:
the name element advertises an `AXShowMenu` action which performs without error and opens nothing,
and after a real right-click `count of menus` still reports 0 on both the element and the process. A
screenshot showed the menu was on screen the entire time. So it is driven by coordinate: a
`CGEventPost` right-click on the element, then a left click at a small offset for the item. See
[Method 26](../Methods.md#method-26), and `cgevent_context_menu_pick` in the runner.

Same shape as `05i`, which was also believed to need a person until a held `CGEventPost` was shown
to reach the stepper arrows.

The two checks that genuinely need an eye -- the popover contents, and the **Active**/**Inactive**
section labels, which are not exposed to accessibility at all -- are `ask_user` steps inside `08b`.
They need a human *observer*, not a human *hand*, which is what keeps them on the Bench side: when
Claude runs the suite it answers them itself with a screenshot
([Method 17](../Methods.md#method-17)).

## Scenario A -- unlocking a face lets its category be retired

A locked face bars the category it holds from being retired, since retiring would take it off a face
that has been told to keep it (`08b` Scenario I checks the bar itself). Lifting the bar is the half
that needs a hand: the Faces tab's lock control belongs to the **top face**, so unlocking face 8
means the cube is actually resting on face 8.

What this proves beyond the bar: the Active box goes live the moment the face is unlocked, with no
re-read of either tab. The tab reads the lock from published app state rather than from the list it
loaded, and a stale read here would look like the bar never lifting.

**Preconditions:** the app running against the test database, Settings closed, `Break` active and on
face 8 with that face locked -- which is where `08b`'s Cleanup leaves it -- and the **device** itself
unlocked and unpaused. Steps 1 and 2 confirm both rather than assuming. The two locks are separate
things: face 8's is the app-side `face.locked` flag this scenario is about, the device's is the cube's
own state, and the menu's Unlock leaves `face.locked` untouched.

- [ ] **(Claude)** Step 1: Confirm face 8 holds `Break` and is locked.
      If it does not, `08b` Scenario I's Step 1 is the statement that puts it back.
```toml step
[[actions]]
action = "sql_query"
query = "SELECT locked FROM face WHERE face_id = 8;"
expect = "1"

[[actions]]
action = "sql_query"
query = "SELECT category_name FROM category WHERE category_id = (SELECT category_id FROM face WHERE face_id = 8);"
expect = "Break"
```
- [ ] **(Claude)** Step 2: Confirm the device is unlocked and unpaused.
      A locked cube silently refuses flips -- no error, no event -- so the flip below would wait out
      its whole timeout while the person doing the flipping watches nothing happen. `07i` runs
      immediately before this and quits the app in its Cleanup, and with `pause_on_lock` on that quit
      pauses and locks the device on the way out; the relaunch does not undo it.
```toml step
action = "ensure_unlocked_unpaused"
```
- [ ] **(You)** Step 3: Flip the cube to the **Break** face (face 8) and leave it there.
      The Faces tab only offers the lock control for the face on top, so this is what makes it
      reachable at all. Detected from the new `device_event` row rather than an answer
      ([Method: Number 19](../Methods.md#method-19)), which is why Step 2 has to have run: a locked
      cube writes no such row and this would time out on a flip that did happen. No y/n and **no
      timeout**: the `prompt` is what raises the ACTION NEEDED banner, and the poll continues on its
      own once the flip lands.
```toml step
action = "wait_for_sql"
query = "SELECT device_face FROM device_event ORDER BY device_event_id DESC LIMIT 1;"
expect = "8"
prompt = "Flip the cube to the Break face (face 8) and leave it resting there -- waiting for the flip."
timeout_seconds = 0
poll_interval = 2
```
- [ ] **(Claude)** Step 4: Open Settings on the Categories tab and confirm `Break`'s Active box is
      dead.
      Methods: [Number 6](../Methods.md#method-6), [Number 10](../Methods.md#method-10). `Break`
      sorts first among the active rows, so it is `checkbox 1`.
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
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return (value of static text 5) & "=" & (enabled of checkbox 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "Break=false"
```
- [ ] **(Claude)** Step 5: Switch to the Faces tab.
      [Method: Number 10](../Methods.md#method-10).
```toml step
use = "method-10"
tab = "Faces"
```
- [ ] **(You)** Step 6: Click the **lock toggle** over the top-left of the drawn device to unlock
      face 8.
      A hand rather than a script: no checklist drives a control inside the Faces tab yet, so the
      lock toggle has no established accessibility path, and a guessed one would fail here as a
      broken step rather than as a finding. The write is what confirms it, not an answer
      ([Method: Number 19](../Methods.md#method-19)) -- but a detected step still needs a `prompt`,
      which is the only thing that raises the ACTION NEEDED banner; without one the runner polls in
      silence and the step reads as though nothing is being asked for. No timeout, as in Step 3.
```toml step
action = "wait_for_sql"
query = "SELECT locked FROM face WHERE face_id = 8;"
expect = "0"
prompt = "On the Faces tab, click the lock toggle over the top-left of the drawn device to UNLOCK face 8 -- waiting for the unlock."
timeout_seconds = 0
poll_interval = 2
```
- [ ] **(Claude)** Step 7: Back on the Categories tab, confirm `Break`'s Active box is now live.
      No relaunch and no re-read between the unlock and this: the box is driven by published state,
      which is the whole reason it can answer at all.
```toml step
[[actions]]
use = "method-10"
tab = "Categories"

[[actions]]
action = "applescript"
script = '''
tell application "System Events"
    tell process "TimeFlip"
        tell group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
            return (value of static text 5) & "=" & (enabled of checkbox 1 as string)
        end tell
    end tell
end tell'''
expect_contains = "Break=true"
```
- [ ] **(Claude)** Step 8: Retire `Break` from that box; confirm face 8 goes back to `Unassigned`.
      The retire the lock was barring, now that it is not.
```toml step
[[actions]]
action = "applescript"
script = '''
tell application "TimeFlip" to activate
tell application "System Events"
    tell process "TimeFlip"
        click checkbox 1 of group 1 of scroll area 1 of group 1 of window "TimeFlip Settings"
        delay 1.5
    end tell
end tell'''

[[actions]]
action = "wait_for_sql"
query = "SELECT category_id FROM face WHERE face_id = 8;"
expect = "0"
timeout_seconds = 30

[[actions]]
action = "sql_query"
query = "SELECT active FROM category WHERE category_name = 'Break';"
expect = "0"
```
- [ ] **(You)** Step 9: Confirm the cube's top face is now unlit.
      Face 8 has no category, so it has no colour, and an unassigned face is the LED off rather than
      whatever it was showing. This is the only step where the clear is visible on the hardware.
```toml step
action = "ask_user"
prompt = "Is the cube's top face (Break) now unlit?"
```
- [ ] **(Claude)** Step 10: Put `Break` back on its locked face and restart the app.
      The Interactive checklists after this one expect the stickered faces to mean what the stickers
      say. The restart is not tidiness: the restore is SQL, and a running app carries face and lock
      state in memory, so without it the next checklist inherits a window still showing `Break`
      retired. It also leaves no Settings window open, which is what closing it was for. Methods:
      [Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2).
```toml step
[[actions]]
action = "sql_exec"
query = "UPDATE category SET active = 1 WHERE category_name = 'Break';"

[[actions]]
action = "sql_exec"
query = "UPDATE face SET category_id = (SELECT MIN(category_id) FROM category WHERE category_name = 'Break' AND active = 1), locked = 1 WHERE face_id = 8;"

[[actions]]
action = "sql_query"
query = "SELECT locked FROM face WHERE face_id = 8;"
expect = "1"

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"
```
