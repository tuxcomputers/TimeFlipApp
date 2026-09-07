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

**No environment variable names the data directory here, and none is standard.** Measured 2026-09-07:
`XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` are all **unset**, and the
only location variables in the environment are `HOME` and `TMPDIR`. macOS has no equivalent of the XDG
variables; the answer comes from `FileManager.urls(for: .applicationSupportDirectory, ...)`, which is
what `DatabaseBootstrap`, `InstanceLock` and `DeveloperConfigFile` all call, and which corelibs already
resolves to `~/.local/share/Facet` on Linux.

The app reads exactly **one** environment variable, `FACET_GOOGLE_CLIENT_JSON`, and reads it as an
*override* with a bundled fallback behind it (`GoogleCredentials.resolve`).

**Untested here, and the reason not to make an environment variable the primary source of a path:** a
`.app` launched from the Finder or the Dock is started by `launchd` and does not inherit variables
exported from a shell profile, so a variable that works under `scripts/run.sh` in a terminal would be
absent on a double-click. Worth confirming before anything depends on it either way.

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
`Tests/Scripted/last-run-mac.md` is stale because `7ade2c7` and the FacetCore split both moved `Sources/`,
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

**Empty as of 2026-09-07.** All twelve questions were answered into *System information about the
Linux* below, in the change that removed them, so the Mac has everything it asked for.

---

## System information about the Linux

**All measured 2026-09-07 on the machine below**, by running the command in each row. Anything not
measured says so.

### The machine

| | |
|---|---|
| Model | **A MacBook Pro running Linux**, `MacBookPro14,2` |
| Chip | Intel Core i7-7567U @ 3.50GHz, 2 cores / 4 threads |
| Memory | 15 GiB |
| Architecture | `x86_64` |
| Host name | `harry-MacBookPro` |

`hostnamectl`, `lscpu`, `free -h`.

**The two machines differ by instruction set as well as by operating system**: `arm64` there, `x86_64`
here. Nothing in the port has depended on it so far -- both are little-endian, which is what the BLE
frame parsing cares about -- but no built artefact is interchangeable between them, and a timing figure
taken on the Mac is not one about this box.

### Operating system

| | |
|---|---|
| Distribution | **Linux Mint 22.3 "Zena"**, Ubuntu 24.04 `noble` base |
| Kernel | 7.0.0-31-generic, `#31~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC`, built 2026-08-10 |
| Desktop | **MATE 1.26.1** |
| Display server | **X11**, `XDG_SESSION_TYPE=x11` |
| Swift target triple | `x86_64-unknown-linux-gnu` |

`/etc/os-release`, `uname -a`, `mate-session --version`, `echo $XDG_SESSION_TYPE`.

**X11, which is what the scripted suite's replacement needed to hear.** Synthetic mouse and keyboard
events -- the half of `scripts/ax-press.py` and `scripts/status-item-click.py` that is not reading the
tree -- go through XTEST here. Under Wayland there is no equivalent a normal process may call, so the
AT-SPI plan in item 12 is possible in the shape planned rather than needing a compositor-specific route.

**[linux-port.md](linux-port.md) said MATE 1.26.2 and that was wrong**: `mate-session` reports 1.26.1.
Corrected there in the same change.

### Toolchain

| | |
|---|---|
| Swift | **6.2** (`swift-6.2-RELEASE`) |
| Install path | `~/.local/swift/swift-6.2-RELEASE-ubuntu24.04`, 3.2 GB |
| On `PATH` by default | **No** |
| SwiftPM | reports itself as `Swift Package Manager 6.2.0-dev` |
| `swiftc` | `~/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin/swiftc` |
| Other toolchains | **None.** That directory holds exactly the one |

`swift --version`, `swift build --version`, `du -sh ~/.local/swift/*`.

Every Swift measurement on this box was taken after:

```sh
export PATH="$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"
```

**`swift` is not on `PATH` in a fresh shell**, so anything scripted that expects to call it needs that
line or an absolute path. That is a difference from the Mac worth designing around rather than
remembering.

### Command-line tools

| Tool | Version | Path |
|---|---|---|
| `sqlite3` | 3.45.1 | `/usr/bin/sqlite3` (**installed 2026-09-07**; the Mac is on 3.51.0) |
| `libsqlite3-0` | 3.45.1-1ubuntu2.7 | `/usr/lib/x86_64-linux-gnu/libsqlite3.so.0` |
| `libsqlite3-dev` | 3.45.1-1ubuntu2.7 | **installed 2026-09-07**, giving `/usr/include/sqlite3.h` and the unversioned `libsqlite3.so` |
| `python3` | 3.12.3 | `/usr/bin/python3` (the system one) |
| `python3-dbus` | 1.3.2 | importable as `dbus` |
| `python3-gi` | 3.48.2 | importable as `gi` |
| `python3-pyatspi` | 2.46.1 | importable as `pyatspi` |
| `bash` | **5.2.21(1)** | `/usr/bin/bash`, and `SHELL=/bin/bash` |
| `git` | 2.43.0 | `/usr/bin/git` |
| `gh` | 2.45.0 | `/usr/bin/gh` (**installed 2026-09-07**; the Mac is on 2.100.0). **Logged into no host** |
| `jq` | 1.7.1 | `/usr/bin/jq` (**installed 2026-09-07**; reports itself as `jq-1.7`) |
| `secret-tool` | 0.21.4 | `/usr/bin/secret-tool`, from `libsecret-tools` (**installed 2026-09-07**) |
| `curl` | 8.5.0 | `/usr/bin/curl` |
| `make` | GNU Make 4.3 | `/usr/bin/make` |
| `wmctrl` | present | -- |
| `xdotool` | **not installed** | -- |
| `flatpak` | present | -- |
| `snap` | **not installed** | -- |
| pyobjc | **absent and staying absent** | `import objc` fails; the seven `scripts/ax-*.py` and `status-item-click.py` are Mac-only |

**bash is 5.2.21, so the bash-5 target the Mac set is met** and nothing here has to be written down to
bash 3. Unlike the Mac there is only one bash on the machine, so which one a script gets is not a
question here.

**`/bin/sh` is `dash`.** A `#!/bin/sh` script carrying a bash-ism runs on the Mac, whose `/bin/sh` is
bash in POSIX mode, and fails here. Nothing checked in has a `#!/bin/sh` line today; this is the reason
to keep it that way.

**Four tools this repository calls were missing until 2026-09-07 and are installed now**, all from
Ubuntu's own archive with no third-party repository: `sqlite3` and `libsqlite3-dev`, which six
checked-in files and the `FacetCore` build need between them; `jq`, wanted by `scripts/ci-local.sh`
alone; and `gh`, wanted by nothing checked in and only by the remote workflow in `CLAUDE.md`.

**Two version gaps between the machines, neither of them currently biting.** The `sqlite3` CLI is
3.45.1 here against **3.51.0** on the Mac, and `gh` is 2.45.0 against **2.100.0** -- Ubuntu 24.04 ships
what it ships. The SQLite gap is the one that could matter, since the schema is shared, so it was
measured rather than assumed: see *The schema applies under this box's SQLite* below.


### Filesystem

| | |
|---|---|
| Volume | `/dev/nvme0n1p2`, **ext4**, 916 GB, 5% used. `/` and `$HOME` are the same filesystem |
| Case sensitivity | **case-SENSITIVE**, measured on both the repository volume and `/tmp` |

`df -T .`, and a `CaseProbe`/`caseprobe` pair in both places.

**Each machine is silent about the hazard it creates and loud about the other's.** A wrong-case path
in a source file or a script works on the Mac and fails here, which is the Mac's half of it. This box's
half is the mirror image: two filenames differing only in case coexist here perfectly, get committed
without complaint, and then cannot be checked out on the Mac at all. Neither compiler nor test run
will say so on the side that did it, so the rule is the same rule from both ends -- never add a name
that collides case-wise with one already in the tree.

### Where things live

| | |
|---|---|
| Repository | `/home/harry/git/TimeFlipApp` |
| Remote | `https://github.com/tuxcomputers/TimeFlipApp.git` (**HTTPS**, matching the Mac) |
| Git identity | Harry Phillips `<harry@tux.com.au>`, the same identity as the Mac |
| App data directory | resolves to `/home/harry/.local/share/Facet`, and **does not exist yet** |
| Databases | **none on this box.** Nothing has run the app here |
| Schema | `database/` at the root is the real directory; `Sources/FacetCore/Resources/Database` is a symlink to `../../../database` and resolves correctly here |

**No XDG variable is set**, measured 2026-09-07: `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`
and `XDG_CACHE_HOME` are all unset. So corelibs' `applicationSupportDirectory` falls back to
`$HOME/.local/share`, which is where `/home/harry/.local/share/Facet` above comes from, and the
platform-aware answer in to-do item 3 needs no variable to be set to be right.

**This box cannot push, and the reason is that nothing here can authenticate.** Measured 2026-09-07,
after `gh` was installed: `gh auth status` answers **You are not logged into any GitHub hosts**, there is
no credential helper configured at any scope (`git config --list --show-origin | grep credential` is
empty), there are no keys in `~/.ssh`, and `GH_TOKEN` and `GITHUB_TOKEN` are both unset. Anonymous
HTTPS works for reading -- `git ls-remote` and `git fetch` both succeed, the repository being public --
so this box can follow the Mac and cannot publish to it.

**`gh auth login` is the outstanding step, and `CLAUDE.md` says which account it has to be.** Push
access to `tuxcomputers/TimeFlipApp` is what matters, not merely being logged in, and `git`'s credential
helper delegates to `gh auth git-credential` once there is a login for it to delegate to.

### There is a keychain here, and the Secret Service is already running

| | |
|---|---|
| Daemon | **`gnome-keyring-daemon` 46.1-2ubuntu0.2, running** with `--components=pkcs11,secrets` |
| D-Bus name | `org.freedesktop.secrets`, present on the session bus |
| Collections | `/org/freedesktop/secrets/collection/login` and `.../session` |
| Keyring files | `~/.local/share/keyrings/login.keyring`, plus `user.keystore` |
| `libsecret-1-0` | 0.21.4-1build3, `/usr/lib/x86_64-linux-gnu/libsecret-1.so.0` |
| `libsecret-1-dev` | 0.21.4-1build3, **installed 2026-09-07**. `pkg-config --modversion libsecret-1` answers 0.21.4 and the header is at `/usr/include/libsecret-1/libsecret/secret.h` |
| `libsecret-tools` (`secret-tool`) | 0.21.4-1build3, **installed 2026-09-07** |
| `seahorse` | 43.0-3build2, for looking inside it by hand |

`pgrep -a gnome-keyring`, `dbus-send --session --dest=org.freedesktop.secrets ... Get Collections`,
`dpkg -l`, `pkg-config --exists libsecret-1`.

**Item 7 already named libsecret, so the counterpart was never in doubt. What is new is that it is
live.** The daemon is running on this box right now, with a `login` collection in it, and it is the same
keyring VSCode asks the password for on its first launch of a session -- unlocked per session rather
than per application. That is worth writing down because it makes item 7 a port onto a running service
rather than a piece of work that has to stand something up first.

**So item 7 has two routes, and the cheaper one needs nothing installed.**

| Route | What it costs | What it gets |
|---|---|---|
| Link **libsecret** | a modulemap over its C API -- the same shape as the `SQLite3` wall, and now the same *remaining* work, `libsecret-1-dev` being installed | The API the desktop expects, with prompting and unlocking handled |
| Talk to **`org.freedesktop.secrets`** over D-Bus | nothing to install: the daemon is up, the name is claimed, and item 10 is bringing a D-Bus layer for BlueZ anyway | The same store, over the bus the port is already going to speak |

The second is worth weighing precisely because of item 10. `org.freedesktop.secrets` and
`org.bluez` sit on different buses -- session and system respectively -- so they are not one connection,
but they are one set of D-Bus mechanics, and `scripts/linux-ble-probe.py` already demonstrates all of it
against BlueZ. **Nothing is decided here**; this records that the choice exists and that neither route
is blocked.

**Untested, and it matters before either route is built**: what happens when the keyring is *locked*.
`DevicePINStore` and `GoogleTokenStore` both answer `unavailable(Int32)` for a Keychain that will not
answer, which is the case that already exists on the Mac -- but the failure here arrives as a prompt to
the user, or as a D-Bus error if there is nobody to prompt, and which one a background app gets has not
been measured.

### Bluetooth and the cube

| | |
|---|---|
| Adapter | `hci0`, `88:E9:FE:5F:1B:52`, name `harry-MacBookPro` |
| Adapter provenance | **built in**, on `dw-apb-uart` rather than USB, manufacturer `0x000f` (Broadcom). Not a dongle |
| BlueZ | **5.72** (`bluetoothctl --version`) |
| Cube, as this box names it | `E8:DB:D8:CF:F9:0F`, address type **random** |
| Cube name | `TimeFlip v2.0` |
| Paired / Bonded / Trusted | **no / no / no**, and that is correct here |
| Where the cube is | **at this machine**, 2026-09-07 17:05 |

`bluetoothctl show`, `bluetoothctl --timeout 15 scan on`, `bluetoothctl info E8:DB:D8:CF:F9:0F`,
`readlink -f /sys/class/bluetooth/hci0`.

**The address is unchanged from the 2026-09-06 run** and the cube answered a 15-second scan on
2026-09-07 at 17:05, so it is physically here now rather than at the Mac. Whether that address survives
a battery change or a `0xFF` factory reset is **untested**, and there is a reason not to assume it does:
BlueZ reports it as a **random** address rather than a public one, and a random address is the kind the
specification allows a device to change. So it is no more a durable identifier than the Mac's per-host
UUID is -- neither machine's name for this cube can be written into a shared table and trusted on the
other.

**BlueZ had forgotten the cube across this boot.** `bluetoothctl info` answered `not available` until a
scan rediscovered it -- there is no bond to persist, the PIN being the whole of the authentication -- so
on this platform finding the cube is *always* a scan. That is the same lesson the device rename cost on
the Mac (2026-08-01), arrived at from the other direction.

**The cube is factory reset every time it moves between the two machines.** Stated by the owner
2026-09-07 as a standing practice, not a measurement, and it is what makes the PIN a non-question: a
reset cube is on the vendor default `000000`, which is the only PIN this box knows and the default
`scripts/linux-ble-probe.py` uses. `DevicePINStore`'s own doc comment already describes this as the
honest outcome of a per-machine Keychain -- a cube carried to a second machine is met by an app that
knows only the vendor default, and the recovery the vendor gave it is taking the batteries out.

**So each handover costs the receiving machine a resync, and that is by design rather than by accident.**
A reset restarts the cube's event counter, which is why the history cursor is read from `device_event`
and checked against what the cube can reach rather than being a stored number (7.1 of
[state-audit.md](state-audit.md)), and it drops the face colours, the LED and blink settings, the task
parameters and the clock -- all of which `DeviceSystemStateRules` already asks the cube about on
connect. Nothing about a handover needs a new mechanism; it exercises the ones a factory reset already
has.

**One advertising detail not previously written down**, and it is a way to spot the cube that does not
depend on its name: it carries manufacturer data under key `0xffff` whose value is
`54 2e 46 6c 69 70 00`, ASCII `T.Flip`. It still advertises **no service UUID**, which is finding 12 and
why discovery must not be filtered on one.

### Display and UI automation

| | |
|---|---|
| Display | `eDP-1`, 2560x1600 at 60Hz, 286x179mm, the only one |
| Automation stack | AT-SPI: `at-spi2-core` 2.52.0, `libatk-adaptor` 2.52.0, `python3-pyatspi` 2.46.1 |
| Registry | **running**: `at-spi-bus-launcher` and `at-spi2-registryd` are both up |
| `toolkit-accessibility` | **false** |
| Present | `wmctrl` |
| Absent | `xdotool`, `accerciser` |

`xrandr --current`, `gsettings get org.gnome.desktop.interface toolkit-accessibility`, `pgrep -a at-spi`.

**The accessibility bus is running but toolkit accessibility is switched off**, so a GTK app started
today would expose no tree to read. Turning it on is one `gsettings set`, and it is a precondition for
to-do item 12 rather than a piece of work in it.

### The suites

| | |
|---|---|
| `swift test` | **cannot run today.** Measured again after the install: 178 errors, 176 of them `no such module SQLite3`, plus the driver's own `error: fatalError`. No test is discovered |
| `Tests/Scripted/` | **cannot run today**: no app binary to drive, and toolkit accessibility is off. The `sqlite3` half of that is fixed as of 2026-09-07 |
| `swift build --target FacetCore` | fails, and the whole of why is below |

**`swift test` stops in the same place `swift build --target FacetCore` does**, which is worth knowing
before reading anything into it: SwiftPM builds `FacetCore` first as a dependency of the test target, so
the run dies on `SQLite3` and never reaches `FacetApp` at all. **The AppKit wall is behind the SQLite3
one and has not been seen from this box yet**, so nothing measured here says anything about it.

**Nothing checks that `sqlite3` is on `PATH` before calling it**, which is worth knowing for the next
fresh machine rather than this one: no script in `Tests/Scripted/` or `scripts/` tests for it, so
`lib.sh`'s `sql()` fails 127 with a `command not found` per query rather than saying once what is
missing. That is `CLAUDE.md`'s rule about swallowed failures seen from the other end -- the failure is
loud, and says the wrong thing.

### What `FacetCore` does on this box

**Measured 2026-09-07, after `libsqlite3-dev` was installed.** `swift build --target FacetCore` **fails
with 177 errors, and all 177 are one message**: `no such module 'SQLite3'`, reported against
`DatabaseBootstrap.swift:2` once per compile unit. Nothing else is reported, because `emit-module` stops
there -- so the raw error count says nothing about how much is wrong, and reading it as 177 problems
would be reading it wrong.

**Installing `libsqlite3-dev` does not clear that on its own, and this is the correction worth carrying
forward.** [linux-port.md](linux-port.md) said `SQLite3` "needs a modulemap **or** `libsqlite3-dev`". It
needs **both**: the Swift toolchain ships no `SQLite3` module for Linux -- there is no modulemap
mentioning sqlite anywhere in the 3.2 GB of it -- so `import SQLite3` cannot resolve however many
headers are on the machine. What the package buys is that the modulemap can point at the **real**
`/usr/include/sqlite3.h` and that linking can find an unversioned `libsqlite3.so`, rather than a
hand-written stub standing in for both. Corrected in that file in the same change.

Two lines over the real header clear it outright, with **no warnings** out of a 641 KB system header:

```
module SQLite3 [system] {
    header "/usr/include/sqlite3.h"
    link "sqlite3"
    export *
}
```

The walls behind it were then measured by peeling them one at a time, with that modulemap and the four
Darwin imports guarded in a **detached worktree** so the tree itself was never edited.

| # | Wall | Files | What it takes |
|---|---|---|---|
| 1 | `SQLite3` | `DatabaseBootstrap`, `DatabaseConnection`, `DebugLog`, `DebugTraceFile` | `libsqlite3-dev` **and** the four-line modulemap above. Cleared outright, real API, no stub |
| 2 | `Security` | `DevicePINStore`, `GoogleTokenStore` | item 7 of [linux-port.md](linux-port.md). **19 distinct missing symbols** (`kSec*`, `SecItem*`, `errSec*`, plus `CFDictionary` and `CFTypeRef`) over **75 diagnostics** |
| 3 | `CryptoKit` | `GoogleOAuthRules` | item 8, swift-crypto. **One** call site: `SHA256` at line 53 |
| 4 | `CoreGraphics` | `SettingsMetrics`, `ReportCalendarMetrics` | one `package typealias CGFloat = Double`, declared **once for the module**. Both files then compile clean |

**With `SQLite3` supplied and the other three merely guarded rather than replaced, the whole of what is
left is 76 errors in three files.** `DevicePINStore` 37, `GoogleTokenStore` 38, `GoogleOAuthRules` 1, and
**not one error in the other 83 files**, with no warnings anywhere. Guarding an import does not implement
it, so those 76 are the call sites themselves -- which is exactly the inventory wanted. The portable half
really is portable, and what stands between this box and a building core is the two Keychain stores and
one hash call.

**The `CGFloat` typealias has to be `package`, and the naive version does not compile.** A plain
`typealias CGFloat = Double` is `internal`, and the metrics types are `package` after the split, so every
member using it fails with `property cannot be declared package because its type uses an internal type`
-- 22 errors across the two files, which looks nothing like a missing-import problem and is entirely a
consequence of stage 3's 589 widenings. `package typealias` clears all 22. Declaring it twice, once per
file, fails differently again (`invalid redeclaration of 'CGFloat'`), so it is one declaration, `package`,
for the module.

**Linking is untested.** Every measurement above stops at `emit-module`, so nothing here says the
`link "sqlite3"` line resolves at link time; that cannot be tried until walls 2 and 3 are actually
implemented rather than guarded.

### The schema applies under this box's SQLite

**Measured 2026-09-07**, now that there is a `sqlite3` to do it with, and it matters because the two
machines are two minor versions apart (3.45.1 here, 3.51.0 on the Mac) over a schema they share.

All **13** files in `database/` applied to a fresh database in file order, each with
`PRAGMA foreign_keys = ON`, exactly as `scripts/compare-database-to-ddl.sh` does it:

| | |
|---|---|
| Files applied | 13 of 13, **no errors** |
| Tables created | 13 |
| `PRAGMA integrity_check` | `ok` |
| `PRAGMA foreign_key_check` | no violations |
| Seeds | `setting` 19, `icon` 43, `colour` 21, `event_type` 8, `timezone` 1 |
| Time | 1.32s |

**So nothing in the DDL needs a SQLite newer than 3.45.1**, and the 1.32s is the same cost
[linux-port.md](linux-port.md) already measured at ~1.15s for a bootstrap -- which is why each test
bootstrapping its own database costs what it costs, on this platform as on the other.

---

## Information required about the Mac

**Questions from the Linux side, for the Mac to answer and then delete.** Each one has the reason it
matters and a command that answers it, so the answer is a measurement rather than a recollection.

**Answering one means: write the fact into *System information about the Mac* above, dated, and remove
the question from here in the same change.** Do not answer inline and do not tick it off in place. When
this heading has nothing under it, the Linux box has everything it needs.

### 1. The Mac's timezone and locale

**Why:** question 11 asked this side for exactly these two so the pair could be compared, and the Mac's
facts section records neither, so the comparison still cannot be made. This box is
**`Australia/Brisbane`** (AEST, +1000, and it observes no DST) with **`en_AU.UTF-8`**. The app owns a
`timezone` table, writes local times into `device_event`, and the `en_US_POSIX` discipline is only
applied to *formatting* -- so a database moved between the machines carries times taken in whichever
zone each was in, and two machines in different zones would be a silent hazard rather than a visible one.

```sh
date +%Z && readlink /etc/localtime
locale | head -3
```

Wanted: the zone, whether it observes DST, and the `LANG`/`LC_*` the app actually launches under -- not
the shell's, if `launchd` gives a `.app` something different.

### 3. What "Paired: yes" means on the Mac

**Why:** the Bluetooth table above says the cube is paired there. Here `bluetoothctl info` reports
`Paired: no` and `Bonded: no`, and that is not a fault -- the cube runs no pairing agent and the PIN is
the whole of the authentication (finding 12). So either macOS holds a real bond that Linux does not, or
"paired" there is this app's own `setting.paired.paired` row being read back. Which it is decides two
things: whether this box connecting to the cube can disturb anything the Mac holds, and whether the
`paired` row in a database copied between the machines means anything on arrival.

```sh
system_profiler SPBluetoothDataType | grep -i -A6 timeflip
sqlite3 ~/Library/Application\ Support/Facet/appdata.sqlite \
  "SELECT setting_value FROM setting WHERE setting_name = 'paired';"
```

Wanted: whether the cube appears in the OS's own list of paired devices, or only in the app's table.
