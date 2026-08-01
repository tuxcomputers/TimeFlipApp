# TimeFlip2 firmware diagnosis harness

This branch reproduces three undocumented behaviours of the TimeFlip2 firmware, on demand, with a
full log of every byte exchanged with the device. It exists so the behaviours can be verified by
someone other than us, on their own hardware, and so a future firmware release can be checked
against the same procedure.

**It is not merged into `main` and is not intended to be.** It carries diagnostic instrumentation
that no shipping build should have, most obviously a re-read loop that adds four seconds to every
rename. Fixes that compensate for the behaviours described here live on the normal feature branches
and do reach `main`; only the instrumentation is confined to this branch.

Findings and the reasoning behind them are in
[`docs/timeflip2-firmware-observations.md`](docs/timeflip2-firmware-observations.md). A captured run
is in [`docs/timeflip2-firmware-evidence.sqlite`](docs/timeflip2-firmware-evidence.sqlite). This file
is only about reproducing it yourself.

## What it demonstrates

1. **Command `0x15` changes the GAP Device Name but not the advertised local name.** The advertised
   name stays `TimeFlip v2.0` no matter what the device is renamed to.
2. **`0x15` never updates the command result characteristic.** It keeps whatever the previous
   command left there, indefinitely, so a client has no acknowledgement to check.
3. **Every command is narrated in plain ASCII on the events data characteristic.** Undocumented, and
   the only completion signal that exists for every command, including the ones in (2).

## What you need

- A Mac (the app is macOS-only) with Bluetooth.
- Swift 6 toolchain, and [swift-bundler](https://github.com/stackotter/swift-bundler) via
  [mint](https://github.com/yonaskolb/Mint).
- A TimeFlip2. The captured run used firmware `FW_v3.64`, hardware `TFv4.1`.

The device is left renamed at the end of the procedure. Nothing else about it is modified apart from
its PIN, which the app resets to the factory default `000000` whenever you use Forget Device.

**A note on the PIN.** Pairing presents one PIN and does not try a second, so the device has to be on
the one the app offers. `run.sh` writes a `config.json` holding the factory default `000000` if you
do not already have one, which is what a device that has never been paired with this app expects. If
pairing reports a wrong PIN, the device is on some other PIN, most likely set by an earlier pairing
with another app: use Forget Device from whatever is still paired to it, which resets it to `000000`.

## Running it

```sh
git checkout timeflip2-firmware-diagnosis
scripts/firmware-diagnosis/run.sh            # fresh test database, build, launch
```

`run.sh` will not touch your production database: it points the app at a throwaway `test.sqlite`
and refuses to start if that redirection has not taken effect.

Then, in the app:

| Step | Action | What it evidences |
|---|---|---|
| 1 | **Scan for Devices**, click your TimeFlip, let it pair | baseline: both names agree |
| 2 | Device tab, **right-click the Name row** → **Rename**, type a new name, press Return | findings 2 and 3 |
| 3 | Wait about 5 seconds for the re-read loop to finish | finding 2 |
| 4 | **Forget Device** | releases it for a fresh scan |
| 5 | **Scan for Devices** again | finding 1 |
| 6 | Click the row and let it pair | finding 1, the delayed correction |

Then extract the log:

```sh
scripts/firmware-diagnosis/extract-evidence.sh
```

That writes `firmware-evidence-<timestamp>.sqlite` in the current directory, containing only the
relevant rows with their original ids and timestamps.

## What you should see

**Finding 1**, at step 5. The scan reports the two names separately, and they disagree:

```
[scan] listed: name=Chomper advert=TimeFlip v2.0 looking-for=Bonker
```

`name=` is the GAP Device Name and `advert=` is the advertisement's local name. The advertised name
is still the factory one despite the device having been renamed. Note also that the GAP name shown
is the name from *before* the most recent rename: macOS caches it and refreshes only on the next
connection, so at step 6 you will see it corrected about two seconds after connecting.

**Findings 2 and 3**, at steps 2 and 3:

```
[ble-tx]    write command ack <- 15 06 42 6F 6E 6B 65 72
[ble-rx]    commandResult -> 17 3A 5A 3B 14 3C 32 3D 32 00 ...
[ble-rx]    eventsData -> 4E 65 6D 65 20 73 65 74
[face-task] 0x15 commandResult re-read at  +250ms: 17 3A 5A 3B 14 ...
[face-task] 0x15 commandResult re-read at  +500ms: 17 3A 5A 3B 14 ...
[face-task] 0x15 commandResult re-read at +1000ms: 17 3A 5A 3B 14 ...
[face-task] 0x15 commandResult re-read at +2000ms: 17 3A 5A 3B 14 ...
```

The `17 3A …` payload is the response to `0x17` (read double-tap parameters), issued during session
setup minutes earlier. It is still there two seconds after the rename, which is what distinguishes
"the client read too early" from "the device never answers this command".

`4E 65 6D 65 20 73 65 74` is ASCII for `Neme set`.

## Checking whether a firmware release has fixed it

Run the same procedure and compare against these, which are the specific things that would change:

| Finding | Fixed when you see |
|---|---|
| 1 | `[scan] listed:` shows `advert=` matching the new name rather than `TimeFlip v2.0` |
| 2 | any `commandResult re-read` line showing `15 02`, or a bare `02`, instead of the stale payload |
| 3 | either the narration is documented, or it is replaced by a real command result per (2) |

Finding 1 has a second, subtler part: even with the advertised name fixed, a client still cannot see
a rename take effect within the connection that made it, because the GAP name only refreshes on
reconnect. If the device begins signalling the change to connected centrals, the log will show
`device reported a new name:` without a reconnect in between.

## Notes on reading the log

Everything is written to the terminal and to the `debug_log` table of the test database, so it can be
queried rather than scrolled:

```sh
sqlite3 ~/Library/Application\ Support/TimeFlip/appdata.sqlite \
  "SELECT debug_log_id, logged_at, tag, message FROM debug_log ORDER BY debug_log_id;"
```

| Tag | Meaning |
|---|---|
| `ble-tx` | bytes written to the device |
| `ble-rx` | bytes received from it, including characteristics this app has no handler for |
| `scan` | one scanned advertisement: both names, and the name being searched for |
| `device-name` | the name read on connect, and any later correction |
| `face-task` | the rename lifecycle, including the re-read loop |

`ble-rx` is logged at the transport, above every handler, so nothing is filtered out on the way in.
