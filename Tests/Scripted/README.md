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

The terminal gets colour; **`logs/screen.txt` is plain text**, written live, so it can be watched with
`tail -f logs/screen.txt` during a run and opened in an editor afterwards without a screenful of escape
sequences.

**Starting from nothing is the default**, because these scripts create categories and time entries and
delete nothing: run after run the database fills up, lists get longer, and a check can start passing
because of a row some earlier run happened to leave. A run from the DDL says what the app does from
nothing, which is the only version of that answer another developer will also get.

```sh
Tests/Scripted/run.sh --keep      # against the database as it stands
```

`--keep` is for looking at what a failed run left.

## The Google account, across a rebuild

A rebuilt database has no `google_account` row, so `10-google-calendar` would skip on every clean run.
The refresh token survives -- it is in the login Keychain, which no rebuild touches -- but the identity
and calendar the app reads are rows, and they do not.

**Connect an account once**, on Settings -> App. From then on `run.sh` captures that row *before* each
rebuild and `00-setup` writes it back afterwards, so the sync is covered on every run without anybody
signing in again.

The captured file is `~/.config/facet/scripted-seed.json`, **outside the repository** and beside the
OAuth client credentials it belongs with. It holds a real email address and a real calendar id, and this
repository takes outside contributions: a seed committed into it would put one developer's account into
everybody's checkout.

## A new calendar every run

`03-settings-window` **deletes** the calendar the last run made, presses Create, and renames the fresh
one to `Facet-test`. All three go through the app's own controls.

**It happens there, before anything records an entry, so the run's events survive the run.** Recording
an entry sweeps every unsynced row into whatever calendar the app currently holds. Replacing the
calendar later would delete one that several scripts had already filled, and the events you would want
to look at afterwards would go with it. Set up first, the calendar ends the run holding everything the
run produced.

Reusing it is what looks reasonable and does not work. Google keeps a deleted *event* for ever as
`cancelled` and will never reissue its id, while Facet derives an event's id from `time_entry_id` --
which a clean run restarts at 1. Emptying the calendar therefore burned exactly the ids the next run was
about to ask for, and every one of those entries then failed to sync for ever. A new calendar has no
cancelled ids in it, so the collision cannot arise.

**The app does the deleting, which is why there is no Keychain prompt.** This used to be a Python script
reading the refresh token with the `security` tool. That is a different program from the one that owns
the Keychain item, so macOS asked permission -- and because signing in again creates a *fresh* item, the
"Always Allow" was thrown away and it asked again after every run that exercised `11`. The app holds that
token already and never has to ask.

**You will not end up with a pile of `Facet-test` calendars.** Steady state is one: each run deletes the
previous before making its own. If a delete fails the id stays in the row, so the next capture picks it
up and the next run tries again -- which matters because `calendarList.list` returns nothing usable under
the `calendar.app.created` scope, so a calendar that escapes cleanup is invisible from then on and can
only be removed by hand in Google Calendar.

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

**Quit is `99`, and everything else comes before it.** It is the one script that ends the app, so
anything after it would run against nothing at all. Numbering it out at the end rather than one past
the last leaves the numbers in between free: a new script takes the next one, and nothing has to be
renumbered to make room.

| | |
|---|---|
| `00-setup` | seeds what a rebuilt database cannot have: the Google account, and history with fractional durations |
| `01-launch` | the database opens, one instance only, the debug log records |
| `02-menu-bar` | the status item, its menu, and the pause on its right half |
| `03-settings-window` | the window opens, the tabs switch, it closes, and the run's calendar is made |
| `04-categories` | create, rename, retire, reinstate, renaming a retired one, and the alerts a namesake raises |
| `05-faces-timing` | a category on a face, the clock starting and pausing |
| `06-time-entries` | a finished segment becoming tracked time, and a blip not |
| `07-history-timer` | it fires while timing and stops when nothing is |
| `08-app-settings` | each row on the App tab written and read back |
| `09-report` | the range, the totals, folding a category open, the sorting |
| `10-google-calendar` | the account, and recorded time reaching the calendar `03` made |
| `11-google-reconnect` | disconnect keeps the calendar, and signing back in still reaches it (**asks you to sign in**) |
| `12-daily-limit` | a category spending its `daily_limit` stops the clock, and every way of starting it again refuses |
| `99-quit` | the way out closes what was open |

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

## CI checks that you ran them

CI cannot run this suite: there is no screen, no Keychain and no Google account on a build machine. What
it can do is refuse a pull request that has no record of a run.

`run.sh` writes **`Tests/Scripted/last-run.md`** at the end of every run, from the recorded run rather
than from anything it was told, and that file is committed. On a pull request,
`scripts/check_interactive_checklists.sh` requires all of:

- the run was on **this** branch;
- it **passed**, with zero failing checks;
- the tree was **clean** when it ran, since a run against uncommitted changes is not evidence about the
  commit it names;
- the commit it names is **in this branch's history**, and nothing under `Sources/`, `Tests/Scripted/` or
  `database/` has changed since.

That last one is why the stamp carries a commit rather than a date. The old checklists recorded a date and
a branch, so a run from before the last five commits looked exactly like one from after them. Editing a
README does not force a re-run; changing the app does.

None of it is enforced on a push to main, where the stamp goes on naming the feature branch that ran it.

**So: run the suite, then commit the stamp along with your change.** If you did not run it, CI will say so
rather than let a green build imply otherwise.

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
