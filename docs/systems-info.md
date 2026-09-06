# The two systems

[← Back to README](../README.md) · [Linux port status →](linux-port.md) · [FacetCore split →](facetcore-split.md)

**Facts each machine needs about the other, so neither has to guess.** Facet is built on a Mac and being
ported to a Linux box, and most of the port's wasted effort so far has come from one side assuming
something about the other that was not true.

**The rule is the one [linux-port.md](linux-port.md) already runs under: every line here is either
measured, with the date and the machine that measured it, or it is marked as unknown.** Nothing in
between, and nothing inferred from what "should" be the case. A guess written down in a facts file is
worse than no line at all, because the next person cannot tell it from a measurement.

**How this file is meant to be used.** Each machine owns two sections: what it *is*, and what it *needs
to know* about the other. You fill in your own facts and you ask your own questions; the other machine
answers them by adding to its own facts section. Nobody writes in the other machine's half.

| Section | Kind | Owned by | Filled by |
|---|---|---|---|
| System information about the Mac | facts, permanent | the Mac | the Mac |
| Information required about the Linux system | **a queue, temporary** | the Mac asking | the Linux box answering, into its own facts section |
| System information about the Linux | facts, permanent | the Linux box | the Linux box |
| Information required about the Mac | **a queue, temporary** | the Linux box asking | the Mac answering, into its own facts section |

### An answered question is deleted, not ticked off

**The two *Information required* sections are the conversation between the machines, not a record of
it.** They are the only part of this file meant to shrink.

1. **Answering means writing the fact into your own *System information* section**, dated, with the
   command that produced it. That is where the answer lives, permanently, next to everything else true
   of your machine.
2. **The machine that answers is the machine that deletes the question**, in the same change that adds
   the fact. Not struck through, not marked done, not moved to an "answered" list: removed. One edit
   does both halves, so the question and its answer can never both be outstanding.
3. **The machine that asked never deletes its own question.** Doing so would be withdrawing it, which is
   a different act and worth saying out loud in the commit message if that is really what is meant.
4. **A blank *Information required* section is the goal, and it means something**: that machine has
   everything it needs from the other. Both blank is the finished state of this file.
5. **A new need is added as a single item**, on its own, whenever it comes up. Most of the time that is
   what these sections will hold -- one question, briefly, until it is answered and goes again.

Concretely, the round trip in each direction:

| The Linux box | The Mac |
|---|---|
| answers a question in *Information required about the Linux system*, writes the fact into *System information about the Linux*, and **deletes that question** | -- |
| adds a new item to *Information required about the Mac* | -- |
| -- | answers it, writes the fact into *System information about the Mac*, and **deletes that request** |
| -- | adds a new item to *Information required about the Linux system* |

So each machine only ever deletes from the section addressed **to** it, and only ever adds to the
section addressed **to the other**.

**This is deliberately not the convention [linux-port.md](linux-port.md) uses.** That file strikes an
answered item through and dates it, because it is a record of what was learned and when. This file is
not a record; it is a working channel, and a queue that keeps its answered items is a queue nobody reads
to the bottom of. The permanence lives in the facts sections.

**The numbers are labels, not positions.** Removing a question leaves a gap, and the gap is correct: it
means that one was answered. Never renumber the rest and never reuse a number, so that a commit message
or a note saying "answered 7" still points at the same thing years later. A new question takes the next
number never yet used.

**Keep it current in the same change that changes the answer**, and re-date the line. A toolchain
upgrade or a distro upgrade makes half of this stale at once, so say when it was taken.

---

## System information about the Mac

**All measured 2026-09-07 on the machine below**, by running the command in each row. Anything not
measured says so.

### The machine

| | |
|---|---|
| Model | MacBook Pro, `Mac17,2` |
| Chip | Apple M5, 10 cores (4 performance, 6 efficiency) |
| Memory | 32 GB |
| Architecture | `arm64` |
| Host name | `TM000403-Harry` |

### Operating system

| | |
|---|---|
| macOS | **26.6.2**, build `25G83` |
| Kernel | Darwin 25.6.0, `xnu-12377.161.14~5`, `RELEASE_ARM64_T8142` |
| Swift target triple | `arm64-apple-macosx26.0` |
| Deployment target | `.macOS(.v14)`, from `Package.swift` |

`sw_vers`, `uname -a`.

### Toolchain

| | |
|---|---|
| Swift | **6.3.3** (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`), swift-driver 1.148.6 |
| Xcode | **26.6**, build `17F113` |
| SwiftPM | Swift Package Manager 6.3.3 |
| `swiftc` | `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc` |
| SDK | `.../Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` |
| Other toolchains | **None.** `/Library/Developer/Toolchains` and `~/Library/Developer/Toolchains` are both empty |

**`Package.swift` declares `swift-tools-version: 6.0` and that is not the compiler.** It is the manifest
and language level the package is written to; the compiler here is 6.3.3, and `docs/installation.md`
states 6.0 as a **minimum**, which 6.3.3 clears. Nothing claims to build *with* 6.0, so there is no
discrepancy between the machines to chase: reading that line as the Mac's compiler version is what put
a phantom question in `linux-port.md`, now withdrawn.

### Command-line tools

| Tool | Version | Path |
|---|---|---|
| `sqlite3` | 3.51.0 | `/usr/bin/sqlite3` |
| `python3` | 3.14.7 | `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3` (python.org, not the system one) |
| `bash` | **5.3.15** | `/opt/homebrew/bin/bash` (Homebrew). Apple's `/bin/bash` is 3.2 and is not what anything here runs under |
| `git` | 2.50.1 | `/usr/bin/git` |
| `gh` | 2.100.0 | `/opt/homebrew/bin/gh` |
| `jq` | jq-1.7.1-apple | `/usr/bin/jq` |
| `swift-bundler` | **not installed** | -- |
| pyobjc-core | 12.1 | with `objc`, `ApplicationServices`, `Quartz`, `AppKit`, `Foundation` all importable |

### The scripted suite runs under bash 5

`Tests/Scripted/run.sh:144` invokes each check as `bash "$script"`, so the interpreter comes from
`PATH` rather than from the `#!/bin/bash` line in the scripts. In a login shell that is Homebrew's
**5.3.15**, and the full suite is always run through `run.sh`, never a script at a time.

Apple's `/bin/bash` 3.2 is still on the machine, as it is on every Mac, but nothing here is written
for it and nothing needs to be. Agent sessions are pinned to bash 5 as well, through `env.SHELL` in
`~/.claude/settings.json`. **Write for bash 5 on both machines.**

**`swift-bundler` is not installed**, although `Bundler.toml` exists and describes the `.app`
(identifier `au.com.tux.facet`, product `FacetApp`, `LSUIElement = 1`). Day-to-day work is
`swift build` / `swift test` / `scripts/run.sh`, which do not need it.

### Filesystem

| | |
|---|---|
| Volume | `Macintosh HD`, APFS |
| Case sensitivity | **case-INSENSITIVE** (`CaseProbe` and `caseprobe` are the same file) |

**This is a trap in both directions and it is silent on this side.** A wrong-case path or filename
compiles and runs here and fails on Linux, and two files whose names differ only in case cannot coexist
here at all. Anything the Linux box adds with a case-colliding name will appear to this machine as a
merge conflict or a vanishing file rather than as what it is.

### Where things live

| | |
|---|---|
| Repository | `/Users/harryphillips/harry.git/TimeFlipApp` |
| Remote | `https://github.com/tuxcomputers/TimeFlipApp.git` (**HTTPS**, not SSH) |
| Git identity | Harry Phillips `<harry@tux.com.au>` |
| App data directory | `~/Library/Application Support/Facet` |
| Databases | `appdata.sqlite` (a symlink, currently → `test.sqlite`), `production.sqlite`, `test.sqlite`, `debug.sqlite`, plus `prod.sqlite` and a `backup/` directory |
| Schema | `database/` at the repository root is the **real** directory; `Sources/FacetCore/Resources/Database` is a symlink to it |

**The remote is HTTPS deliberately.** `gh auth switch` does not change which SSH key is offered, so an
SSH remote authenticates as the wrong GitHub account for this repo. Whatever the Linux box uses, it
needs to reach `tuxcomputers/TimeFlipApp` as an account with access.

**`appdata.sqlite` is a symlink and which database it points at changes.** `scripts/switch-database.sh`
moves it between `production` and `test`. Never assume which one is live: read the link.

### Bluetooth and the cube

| | |
|---|---|
| Controller address | `5C:9B:A6:81:3B:00`, chipset `BCM_4388C2` |
| Cube, as this Mac names it | `FA1DDE60-5DBB-D5E9-B53C-881E16916B5E` |
| Cube name | `TimeFlip v2.0` (`device_name.previous_name` is the same) |
| Paired | yes |

**The identifier above is this Mac's name for the cube and is meaningless anywhere else.** CoreBluetooth
hands out a per-host mapping, not the device's address, so the `device_uuid` row in a database copied to
the Linux box names nothing there. The Linux box sees the same cube as `E8:DB:D8:CF:F9:0F`
(`linux-port.md`), a real address. Already written up in
[timeflip2-firmware-observations.md](timeflip2-firmware-observations.md) finding at line 285, and in
`DeviceScanRules.swift:10`.

**So `device_uuid` is a platform-specific value living in a shared table**, and a database moved between
the two machines carries a pairing that only one of them can act on. Nothing has been decided about
that yet; it is listed in the questions below.

### Display and UI automation

| | |
|---|---|
| Display | Built-in Liquid Retina XDR, 3024 x 1964, Retina |
| Automation | pyobjc against the accessibility API: `scripts/ax-press.py`, `ax-dump.py`, `ax-set.py`, `ax-hold.py`, `ax-key.py`, `ax-alert.py`, `scripts/status-item-click.py` |

The scripted suite drives the **real** mouse and keyboard on this screen and needs a person present to
turn the cube. It is never run unattended, and never by an agent.

### The suites

| | |
|---|---|
| `swift test` | **1718 tests**, all passing, measured 2026-09-06 |
| `Tests/Scripted/` | 36 shell scripts: 14 needing no cube (`00`-`13`), 17 needing one (`50`-`66`) |
| Last scripted run | branch `chore/connecting`, commit `7c9169d`, 2026-09-05 -- **stale**, see below |

**Docs that say "1632 tests" are out of date**; the real count is 1718. The scripted stamp in
`Tests/Scripted/last-run.md` is stale because `7ade2c7` and the FacetCore split both moved `Sources/`,
and CI will refuse the branch until a fresh run is committed.

### CI

| | |
|---|---|
| Where | GitHub Actions, `.github/workflows/tests.yml` |
| Build and test jobs | `runs-on: macos-15` (two of them: merged-into-base, and branch as-is) |
| What they run | `swift build`, `swift test`, `scripts/check_interactive_checklists.sh` |
| The `ubuntu-latest` job | **Aggregator only.** It checks that the required jobs succeeded; it builds nothing |

**Nothing in CI compiles the project on Linux today.** The one Ubuntu runner is a status gate. So the
Linux build is verified only by hand on the Linux box, and a change that breaks it will go green here.
The Swift version on the `macos-15` runner has **not** been measured and is not assumed to match the
6.3.3 above.

---

## Information required about the Linux system

**Questions from the Mac side, for the Linux box to answer and then delete.** Each one has the reason it
matters and a command that answers it, so the answer is a measurement rather than a recollection.

**Answering one means: write the fact into *System information about the Linux* below, dated, and remove
the question from here in the same change.** Do not answer inline and do not tick it off in place. When
this heading has nothing under it, the Mac has everything it needs.

Where an answer is already in [linux-port.md](linux-port.md), it is fine to say so and cite it. These
are asked again because that file records a spike from a scratch directory, and some of it may have
moved on.

### 1. The toolchain, exactly

**Why:** so each side knows what compiler the other's results came out of. A build that passes on one
version and not another is a fact about the toolchains, and neither machine can see the other's.

**Not asking about Swift 6.0.** That question was withdrawn: it existed only because
`swift-tools-version: 6.0` in `Package.swift` was read as "the Mac builds with 6.0". It is the manifest
and language level, not the compiler. The Mac is on **6.3.3**, Linux used **6.2**, `docs/installation.md`
states 6.0 as a **minimum** which both clear, and no machine has 6.0 or needs it.

```sh
swift --version && which swift
ls ~/.local/swift/            # or wherever toolchains are unpacked
```

Wanted: version, exact install path, and whether it is on `PATH` by default.

### 2. Distro, kernel, desktop

**Why:** the tray/menu-bar shape of the app depends on the desktop, and `linux-port.md` says MATE has a
native tray where GNOME does not.

```sh
cat /etc/os-release | head -3 && uname -r && echo "$XDG_CURRENT_DESKTOP / $XDG_SESSION_TYPE"
```

Wanted: distro and version, kernel, desktop environment, and **X11 or Wayland** -- the last decides
whether AT-SPI automation for the scripted suite is even possible in the form planned.

### 3. `bash`, and what `/bin/sh` is

**Why:** shared scripts. The Mac side is bash **5.3.15**, so bash 5 is the target on both machines and
there is nothing to write down to.

```sh
bash --version | head -1 && ls -l /bin/sh
```

Wanted: confirmation it is bash 5.x, and whether `/bin/sh` is `dash` -- because a `#!/bin/sh` script
that works here may rely on bash-isms that the Mac's `/bin/sh` tolerates and `dash` does not.

### 4. SQLite

**Why:** the spike used a hand-written 25-symbol modulemap rather than the real headers, and
`linux-port.md` says stock Mint ships only `libsqlite3.so.0` without the unversioned symlink that
linking needs.

```sh
sqlite3 --version
dpkg -l libsqlite3-dev 2>/dev/null | tail -1
ls -l /usr/lib/x86_64-linux-gnu/libsqlite3.so*
```

Wanted: the `sqlite3` CLI version, the library version, whether `libsqlite3-dev` is now installed, and
whether the shim is still in use.

### 5. Python and the D-Bus bindings

**Why:** `scripts/linux-ble-probe.py` is the reference BLE implementation and needs them, and any
AT-SPI automation will too.

```sh
python3 --version
python3 -c "import dbus, gi; print('dbus and gi present')"
python3 -c "import pyatspi; print('pyatspi present')"
```

### 6. BlueZ and the radio

**Why:** the BlueZ backend is to-do item 10 and is the largest device-side piece left.

```sh
bluetoothctl --version
hciconfig -a 2>/dev/null | head -5    # or: bluetoothctl show
```

Wanted: BlueZ version, adapter name and address, and whether the adapter is the built-in one or a
dongle.

### 7. The cube, from that side

**Why:** the two machines name the same cube differently and a shared database carries only one of the
two names. This Mac sees `FA1DDE60-5DBB-D5E9-B53C-881E16916B5E`; `linux-port.md` records
`E8:DB:D8:CF:F9:0F` there.

Wanted: confirmation the address is still that, whether it has changed across a power cycle or a factory
reset, and **whether the cube is physically at that machine or this one** -- with a rough sense of when,
because only one machine can hold the connection at a time.

### 8. Filesystem and where the repo lives

**Why:** this Mac's volume is **case-insensitive**. A file added there whose name collides case-wise
with an existing one cannot be checked out here.

```sh
df -T . | tail -1
mkdir -p /tmp/ct && touch /tmp/ct/CaseProbe && ls /tmp/ct/caseprobe 2>/dev/null \
  && echo "case-insensitive" || echo "case-sensitive"
pwd
```

Wanted: filesystem type, case sensitivity, and the absolute path the repository is checked out at.

### 9. How that machine reaches GitHub

**Why:** this Mac uses an **HTTPS** remote on purpose, because `gh auth switch` does not change the SSH
key offered and an SSH remote authenticates as the wrong account for `tuxcomputers/TimeFlipApp`.

```sh
git remote -v && git config user.name && git config user.email
gh auth status 2>&1 | head -8
```

Wanted: remote URL and protocol, the git identity commits are made under, and which GitHub account has
access. If pushes fail with `403`, this is why.

### 10. Where the app's data directory resolves

**Why:** `linux-port.md` records the one XCTest failure as corelibs correctly resolving
`applicationSupportDirectory` to `~/.local/share/Facet` where the test asserts the macOS path. To-do
item 3 is making that platform-aware, and it is awkward because the literal is also in the seeded
`debug` row of `database/011_setting.sql`.

```sh
echo "${XDG_DATA_HOME:-$HOME/.local/share}/Facet"
ls -la "${XDG_DATA_HOME:-$HOME/.local/share}/Facet" 2>/dev/null
```

Wanted: the resolved path, whether `XDG_DATA_HOME` is set, and whether a Facet directory exists there
yet.

### 11. Locale and timezone

**Why:** the app is dense with date handling and owns a `timezone` table. The `en_US_POSIX` discipline
is what made the date code port cleanly, and it would be worth knowing the two machines are not silently
in different zones when a database moves between them.

```sh
timedatectl 2>/dev/null | head -4 || (date +%Z && cat /etc/timezone)
locale | head -3
```

### 12. What actually builds and passes there, today

**Why:** `linux-port.md`'s numbers come from a scratch package that was never checked in. Now that
`Sources/FacetCore` exists as a real target, the interesting question is what it does on that machine.

```sh
swift build --target FacetCore 2>&1 | tail -5
```

Wanted: whether `FacetCore` builds as-is, what it needs first (`FoundationNetworking` shims, the SQLite
modulemap), and the error count if it does not. **This is the most useful single answer on the list**,
because the whole point of the split was to make that question askable.

---

## System information about the Linux

> **To be filled in by the Linux machine.** Mirror the shape of the Mac section above -- the machine,
> operating system, toolchain, command-line tools, filesystem, where things live, Bluetooth and the
> cube, display and automation, the suites. Date every line and say what command produced it.
>
> This is where the answers to the twelve questions land, one at a time, **each one deleted from
> *Information required about the Linux system* as it is written down here.** Delete this note when
> there is something here.

---

## Information required about the Mac

> **Asked by the Linux machine, answered and then deleted by the Mac.** Whatever the Linux side needs to
> know about this Mac and cannot see for itself: toolchain details, paths, how the cube is paired here,
> what a macOS-only framework actually does in a given file, how something is drawn, what a scripted
> check observes.
>
> Ask with a reason and, where it makes sense, the command that would answer it. Add items here one at a
> time as they come up; numbers start at 1 and are never reused.
>
> **The Mac answers by writing the fact into *System information about the Mac* above and removing the
> request from here in the same change**, never by replying inline. Delete this note when there is
> something here.
