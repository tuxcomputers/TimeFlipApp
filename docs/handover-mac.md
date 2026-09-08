# Handover: for the Mac

[← Back to README](../README.md) · [The other direction →](handover-linux.md) · [The two systems →](systems-info.md)

**This file is for the Mac to act on. Everything in it was written by the Linux box.**

Its mirror is [handover-linux.md](handover-linux.md), which the Mac writes and the Linux box acts on.
Neither machine edits the file addressed to itself except to delete from it, and neither deletes from the
file it wrote.

**Two developers handing work to each other across a desk, and this is the note left on the keyboard.**
Both machines commit to the same branch under the same identity, so the only way one can ask the other
for something is to write it down where the other will look.

## How to work through this

1. **Take the items in whatever order suits.** They are numbered so a commit message can name one, not
   to say which comes first. Where one genuinely blocks another the item says so.
2. **Delete an item the moment it is done, one at a time, and commit that deletion on its own.** The
   commit message is where the answer goes -- what you ran, what came back, what you changed because of
   it. Not struck through, not ticked, not moved to a "done" list: removed. One item, one commit, so the
   history reads as a conversation rather than as a bulk edit.
3. **Put facts where facts live, not here.** Something true about this machine goes in *System
   information about the Mac* in [systems-info.md](systems-info.md); something the hardware does goes in
   [timeflip2-firmware-observations.md](timeflip2-firmware-observations.md); something about the port
   goes in [linux-port.md](linux-port.md). This file is the asking, and it is meant to empty.
4. **An item you cannot do stays put, with a line saying why.** That is an answer too, and a more useful
   one than silence -- but say it in the item rather than deleting it, so whoever asked can decide what
   to do instead.
5. **Numbers are labels and are never reused.** A gap means an item was finished. A new item takes the
   next number never used before, so a commit message saying "handover 3" still means the same thing
   years later.
6. **When you have done everything you can, write what you want back.** Add items to
   [handover-linux.md](handover-linux.md) for the other machine. A blank file on both sides is the
   finished state.

---

## 6. Confirm the two-stamp gate behaves under macOS `awk` and `sed`

**`scripts/check_interactive_checklists.sh` now reads a stamp per platform** (`f458227`).
`check_the_suite_was_run` takes the platform name and the stamp it speaks for and is called twice, the Mac
deciding the exit status and the Linux half reported but not enforced until `LINUX_IS_ADVISORY=0`.

**Why this needs your eyes rather than mine: CI runs this script on `macos-15`, and I can only run it here.**
The file already carries a scar from exactly that gap -- the comment above the `count_trouble` awk explains
that macOS awk will not split on an escaped pipe in `FS`, that the gate silently passed everything as a
result, and that nobody saw it because the code path only ran when a skip existed. My change did not touch
that awk, but it did make `STAMP` a `local` in a function that is now called twice, and "works under one
shell, quietly does nothing under another" is the shape this script has been bitten by before.

Six cases were exercised here, and the exit statuses were 0, 1, 0, 0, 1, 0:

```sh
./scripts/check_interactive_checklists.sh --branch feature/linuxPort              # 0, as CI runs it
LINUX_IS_ADVISORY=0 ./scripts/check_interactive_checklists.sh --branch feature/linuxPort   # 1
LINUX_IS_ADVISORY=0 SCRIPTED_STAMP_LINUX=<a copy of the Mac stamp> ...            # 0
SCRIPTED_STAMP_LINUX=<a stamp naming another branch> ...                          # 0, reported only
SCRIPTED_STAMP=<a stamp naming another branch> ...                                # 1, the Mac still bites
./scripts/check_interactive_checklists.sh                                         # 0, a push to main
```

Running those six on the Mac and finding the same numbers is the whole ask. Nothing under `Sources/`,
`Tests/Scripted/` or `database/` changed, so run 172 is still current and this costs no cube time.

## 7. A decision: should the gate watch `Package.swift`?

**It does not today, and the manifest decides what gets built.** The staleness check is
`git diff "$ran_commit" HEAD -- Sources Tests/Scripted database`, so a commit that changes only
`Package.swift` leaves the stamp looking fresh while the app it describes has changed -- a target's file
list, an exclusion, a dependency, or on this branch the whole `#if os(Linux)` graph. That is the same class
of thing the watch exists to catch, arriving by a path it does not look at.

**I have not changed it, because the cost is yours to weigh rather than mine.** Adding `Package.swift` to
`watched` is one word and closes the hole. It would also mean every manifest edit forces another 36-minute
run with the cube -- and during this port the manifest is edited often, mostly for things that cannot
affect macOS at all, being inside `#if os(Linux)`. So the honest options are three, and the middle one is
the one I would take:

1. **Watch it.** Correct and blunt: any manifest edit costs a re-run, including Linux-only ones.
2. **Watch it, but let the Linux branch of it be free.** Harder to express in a `git diff` pathspec than it
   sounds, since the diff is textual and knows nothing about `#if os(Linux)` -- it would need the check to
   diff the file and ask whether anything outside that branch moved.
3. **Leave it, and write down that it is deliberate**, so the next person to notice the hole finds the
   reasoning instead of re-deriving it.

Nothing is blocked on this. It is worth a decision rather than a rediscovery, and `Package.swift` has not
changed since run 172, so whichever way it goes it costs nothing today.

## 8. Run 173, and check the platform seam did not change what the Mac does

**Blocking, and it is my doing.** `bf8f711` and `88e821d` put everything platform-specific behind
`Tests/Scripted/platform.sh`, which means `Tests/Scripted/` changed and run 172 is stale. The gate names
the files:

```
The scripted suite has not been run on this branch as it stands:
  - the app or the checks have changed since that run:
      Tests/Scripted/lib.sh
      Tests/Scripted/platform.sh
      Tests/Scripted/run.sh
      Tests/Scripted/testlog.sh
```

**The macOS values are a transcription, not a redesign, and that is the thing to check.** `PLATFORM` comes
from `uname`; `SUPPORT`, `DB`, `DEBUG_DB`, `APP`, `BINARY`, `PROCESS_NAME` and `STAMP` hang off it. Every
Mac value was copied across unchanged, and `BINARY` resolves character for character to the literal that
was sitting in `testlog.sh`. I checked both platforms' values with `PLATFORM_OVERRIDE`, which is in the
file for that purpose -- but an override can only prove the *paths*, never the *methods*, since
`ax-press.py` was never going to run here.

So what run 173 is really testing is that the seam is invisible on the Mac. The places it could bite:

- `platform_quit_app` -- the same two `python3` calls in the same order with the same messages, now one
  function called from three places (`run.sh` twice, `lib.sh` once).
- `platform_binary_built_at` -- was `stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S'` against a literal path, now
  against `$BINARY`. It feeds the run record's `binary_built_at` and the `launching ...` step.
- `platform_signing` -- the `codesign` case moved wholesale, pipefail measurement and all. If run 173's
  record says `ad-hoc` against a properly signed app, that is this and not the app.
- `SUPPORT_TILDE` in `00-setup` -- it writes the debug trace's directory into a `setting` row, and the
  app expands the tilde. It should be byte-identical to what was there.
- `platform_app_instances` in `01-launch` -- was `pgrep -x Facet | wc -l | tr -d ' '`, same pipeline now
  behind a name.
- **`ensure_app_running`, which was restructured rather than only re-spelled** (`0ea9fb5`). It is now the
  step alone -- up? declared? stale? build, launch, wait -- with `platform_build_app`,
  `platform_launch_app` and `platform_warn_if_unsigned` under it. The macOS build inside
  `platform_build_app` is the same `mint run stackotter/swift-bundler@main bundle Facet --codesign
  --identity "$identity"`, with `generate-credentials.sh` before it and the identity still passed as its
  own argument. **The one behavioural change on the Mac is a new check before the build**: it asks whether
  a product is declared at all, which on the Mac is `[ -f Bundler.toml ]` and should never fire. And
  `platform_build_app` now refuses if the build reports success but leaves no executable at `$BINARY` --
  new, and it should never fire either, but it is the read-back rule and it is worth knowing it is there.

**Everything else was checked here as far as it can be**: all 35 files parse under the gate, `lib.sh`
sources cleanly, `run.sh` on Linux refuses at the top with exit 2 and writes no log, no stamp and no
database, and an unknown `uname` is refused rather than guessed.

`run.sh` needs no new argument -- it writes `last-run-mac.md` on the Mac exactly as before, because that is
what `platform.sh` names there.

## 9. Build `FacetMac` — the rename is unverified on macOS by construction

**`b693245` renamed `FacetApp` to `FacetMac`, the tests to `FacetTests`, and the package to `Facet`.** The
Linux app is not an addition to the macOS one and the naming said otherwise; the package name was the same
fault, and it leaked into `Bundle.module`, which derived `FacetApp_FacetCore.resources` from it on *both*
platforms.

**I cannot compile any of it.** `FacetMac` is absent from the Linux target list by design -- that is what
lets `swift test` run here at all -- so nothing on this machine builds it. `swift build`, `swift test` (906)
and the scripted gate all pass on Linux, and none of that is evidence about the half you have.

**What I can tell you is what the rename actually touched inside `Sources/FacetMac/`: comments, and
nothing else.** No identifier was renamed there. The one substantive line is `ActivityIcon.swift:75`, whose
comment now names `Facet_FacetMac.bundle` -- worth an eye, because that file reads a bundle by a derived
name and is the one place in the macOS sources where the package name is described rather than computed.

Where it could still bite, in the order I would check:

1. **`swift build`.** The product is `FacetMac` and `Bundler.toml`'s `product` follows it. `[apps.Facet]` is
   unchanged, so the built app is still `Facet.app` and `platform.sh`'s `BINARY` path is untouched.
2. **The resource bundle.** `Facet_FacetCore.resources` and `Facet_FacetMac.resources` are what SwiftPM
   generates now. On Linux the equivalent renamed cleanly and the app still found its icon; on macOS the
   `.app` is assembled by `swift-bundler`, which is a different path to the same question.
3. **`scripts/package.sh`** reads `Sources/FacetMac/Resources/google-client.json`, and its comment about the
   executable being named for the app rather than the product is still true.
4. **`swift test`** on the Mac, where none of the 48 Linux exclusions apply, so 47 files' `@testable import
   FacetMac` all compile for the first time.

Stale build products are worth clearing first: `.build/debug/` here still had `FacetApp_*.resources`
directories beside the new `Facet_*` ones until a clean build, which is harmless but confusing to read.

**This costs no extra cube time.** Run 172 was already stale from the platform seam (item 8), so items 8 and
9 are one run between them.
