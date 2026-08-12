# Single Instance Checklist

### Last run - 2026-08-11 18:25 on the branch 'feature/inactiveID'

Covers `SingleInstanceLock`: a second copy of the app stands down instead of running alongside the
first. Two instances used to be possible, each with its own status item and its own BLE client
competing for the same cube, which is what `Tests/Methods.md` Method 2 carried a standing warning
about after `09b` inlined a bare launch on 2026-08-02.

`Tests/TimeFlipAppTests/SingleInstanceLockTests.swift` already pins the lock itself, including that
a second holder is refused and that the lock is free again once the first lets go. What those cannot
reach is the thing being claimed here: that a **real second launch of the built app** exits on its
own, quickly, without disturbing the instance already running. That needs two processes and a built
bundle, so it lives here.

Scenario B is the half the rest of the suite depends on. Nearly every checklist quits and relaunches
(Method 3 then Method 2), so a lock that outlived its process would not fail this checklist alone,
it would fail everything after it.

DB path: `~/Library/Application Support/TimeFlip/appdata.sqlite`

## Setup

**Preconditions:** the state `Tests/00-test-setup.md` leaves behind: test database, app running,
device paired and connected.

- [ ] Step 1: Confirm `db_type` reads **test**.
```toml step
use = "method-24.a"
setting = "db_type"
expect = '{"type":"test"}'
```
- [ ] Step 2: Confirm exactly one instance is running, and note which one it is.
The premise of the whole checklist. `pgrep`'s pattern is written `TimeFlip[.]app` so it cannot match
the shell running it: that process's own command line carries the brackets, which the regex does not.
```toml step
[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | wc -l | tr -d ' '"
expect = "1"

[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | head -1"
capture = "incumbent_pid"
```

## Scenario A -- a second launch stands down and leaves the first alone

**Preconditions:** Setup complete: one instance running, its pid captured.

- [ ] Step 1: Launch the app again in the **foreground** and confirm it says it is exiting.
Foreground on purpose, unlike [Method 2](../Methods.md#method-2), which backgrounds it: the point is
that this returns at all. `2>&1` because the message goes to stderr, and a shell step asserts on
stdout.

The `alarm` wrapper is what makes a regression **fail** rather than hang. A duplicate that did not
stand down would run forever, and a shell step has no timeout of its own, so without this the whole
run would stop here rather than report anything. On expiry the alarm kills the runaway duplicate and
the non-zero exit fails the step. `perl` because it ships with macOS: `timeout`/`gtimeout` are
homebrew coreutils and are not there to be relied on. 15 seconds is generous against the real
figure, which is immediate.
```toml step
action = "shell"
command = "perl -e 'alarm shift; exec @ARGV' 15 ./.build/bundler/apps/TimeFlip/TimeFlip.app/Contents/MacOS/TimeFlip 2>&1"
expect_contains = "already running"
```
- [ ] Step 2: Confirm there is **still** exactly one instance.
```toml step
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | wc -l | tr -d ' '"
expect = "1"
```
- [ ] Step 3: Confirm the survivor is the **original** process, not a replacement.
The distinction Step 2 cannot make on its own: a duplicate that killed the incumbent and took over
would also leave exactly one instance running, and would be just as wrong.
```toml step
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | head -1"
expect = "$incumbent_pid"
```
- [ ] Step 4: Confirm the incumbent still holds the device.
The reason two instances mattered. Read from the live `connection` setting rather than a log row,
because what is being asserted is the state right now, not that something was once logged.
```toml step
action = "sql_query"
query = "SELECT json_extract(setting_value, '$.connected') FROM setting WHERE setting_name = 'connection';"
expect = "1"
```

## Scenario B -- quitting hands the lock on

**Preconditions:** Scenario A complete, the original instance still running and connected.

- [ ] Step 1: Quit and relaunch, and confirm the new instance reaches the device.
Proof the lock was released rather than merely taken: a lock that outlived its process would leave
this launch standing down, and the reconnect below would never arrive. Methods:
[Number 3](../Methods.md#method-3), [Number 2](../Methods.md#method-2),
[Number 4](../Methods.md#method-4).
```toml step
[[actions]]
use = "method-24.b"
capture = "before_relaunch_id"

[[actions]]
use = "method-3"

[[actions]]
use = "method-2"

[[actions]]
use = "method-4"
since_id = "$before_relaunch_id"
timeout_seconds = 60
```
- [ ] Step 2: Confirm exactly one instance is running, and that it is a **new** process.
Together these say the relaunch actually happened: one instance rules out the old one surviving
alongside, and a changed pid rules out the quit having quietly failed and this step reading the
instance that never left.
```toml step
[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | wc -l | tr -d ' '"
expect = "1"

[[actions]]
action = "shell"
command = "pgrep -f 'TimeFlip[.]app/Contents/MacOS/TimeFlip' | head -1"
capture = "relaunched_pid"

[[actions]]
action = "sql_query"
query = "SELECT CASE WHEN '$relaunched_pid' = '$incumbent_pid' THEN 'the app never restarted: same pid $incumbent_pid' ELSE 'restarted' END;"
expect = "restarted"
```
