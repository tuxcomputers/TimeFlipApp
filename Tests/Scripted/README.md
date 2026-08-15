# Scripted checks

Checks that drive the real app and read the real database. `swift test` is hermetic and never opens a
window or touches a radio, so a feature can be entirely green there and broken the moment it runs.
These are what say it works.

They need no AI, no Claude, and nothing installed beyond what building the app already needs.

```sh
Tests/Scripted/run.sh
```

That **rebuilds `test.sqlite` from the DDL**, builds the app if the sources are newer than the bundle,
launches it, runs every script in order, quits it, and writes everything to `logs/screen.txt` as well as
the terminal.

**Starting from nothing is the default**, because these scripts create categories and time entries and
delete nothing: run after run the database fills up, lists get longer, and a check can start passing
because of a row some earlier run happened to leave. A run from the DDL says what the app does from
nothing, which is the only version of that answer another developer will also get.

```sh
Tests/Scripted/run.sh --keep      # against the database as it stands
```

`--keep` is for looking at what a failed run left, and for one thing the clean run cannot cover: **a new
database has no Google account**, so `10-google-calendar` skips. The refresh token lives in the Keychain
and survives, but the account the app reads is in the database and does not. To include that section,
sign in once on Settings -> App and then use `--keep`.

## Before you run

**Point the app at the test database.** The scripts refuse to run otherwise, and say so:

```sh
scripts/switch-database.sh test
```

They write real categories, segments and time entries, and the default run **deletes and rebuilds
test.sqlite**. Production holds time you actually recorded, and nothing here will touch it -- but that
guard is the only thing standing between the two, which is why every script checks before it starts.

**Take your hands off.** These drive the real cursor and the real window on your real screen. A click
you make while a script is running lands in whatever the script just opened.

## Running some of them

```sh
Tests/Scripted/run.sh 04              # scripts whose name contains "04"
Tests/Scripted/run.sh categories      # or a word from the name
Tests/Scripted/run.sh --keep-running  # leave the app up afterwards, to look at a failure
Tests/Scripted/run.sh --keep 09       # one script, against the database as it stands
```

Running a subset still rebuilds the database unless `--keep` is given, and most scripts depend on what
the ones above them made -- `09-report` needs the entries `06` records. `--keep` is usually what you
want when running one on its own.

Each script also runs on its own, and launches the app itself if it is not already up:

```sh
bash Tests/Scripted/04-categories.sh
```

## What a failure looks like

```
  a new category appears in the list
    PASS
  the renamed category keeps its icon
    FAIL  expected 'Coffee', got 'None'
```

**What is being checked prints before the verdict**, on its own line, so a run can be watched as well as
read afterwards. Several checks wait on a network round trip or a ten-second timer, and a single line
printed on the way out would leave the terminal silent for as long as the slowest step takes with nothing
saying which step it is.

Then, at the end of the script, the count and every failure again. **A failing script stops the run**:
each one starts from the state the last one left, so carrying on would report the next failure in the
wrong place.

## The order, and why it is that order

Each script depends on what the ones above it proved, so they read top to bottom as the app coming up
and then being used.

| | |
|---|---|
| `01-launch` | the database opens, one instance only, the debug log records |
| `02-menu-bar` | the status item, its menu, and the pause on its right half |
| `03-settings-window` | the window opens, the tabs switch, it closes |
| `04-categories` | create, rename, retire, reinstate |
| `05-faces-timing` | a category on a face, the clock starting and pausing |
| `06-time-entries` | a finished segment becoming tracked time, and a blip not |
| `07-history-timer` | it fires while timing and stops when nothing is |
| `08-app-settings` | each row on the App tab written and read back |
| `09-report` | the range, the totals, folding a category open, the sorting |
| `10-google-calendar` | the account, the calendar, and an entry reaching it |
| `11-quit` | the way out closes what was open |

## How a check is written

Three things, and everything in `lib.sh` exists to keep them honest.

**Evidence comes from the database.** A check waits for a `debug_log` row or queries a table. Asking a
person "did that work?" records their optimism, and these scripts are meant to be run by somebody who
was not watching.

**Every wait is baselined.** `mark` takes the newest `debug_log` id *before* the action, and `wait_for`
only looks past it. Without that, a matching row from ten minutes ago passes a step that did nothing --
and this database is used by a person as well as by these scripts, so a total count is never safe to
assert on.

**Nothing is cleaned up afterwards.** The rows a run creates are left where they are. They are evidence,
and a script that tidied up would be deleting the thing somebody wants to look at when it fails.

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_test_database
ensure_app_running
start "what this script checks"

since=$(mark)
press some-button
expect_log "the button did the thing" "$since" "%the thing%"

check "the table agrees" "1" "$(sql 'SELECT ...;')"

finish
```

## When one of these fails

The app is still there if you passed `--keep-running`. Beyond that:

```sh
sqlite3 ~/Library/Application\ Support/Facet/appdata.sqlite \
  "SELECT logged_at, tag, message FROM debug_log ORDER BY debug_log_id DESC LIMIT 40;"

python3 scripts/ax-dump.py          # what the script can see and press
```

`Tests/Methods.md` is the reference for both, and for the traps that have already cost time: what needs
a real mouse event, why a status item is not in the menu bar's accessibility tree, and why launching
the `.app` directly can run a binary older than the change you are testing.
