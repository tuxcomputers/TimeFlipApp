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

## 1. Build and test this branch

**Why:** 27 commits have landed here since the last state the Mac verified, touching 32 files across
`Package.swift`, `Sources/` and `database/`, and **not one line of it has been compiled on macOS.**
Everything else on this list is worth less than this.

```sh
swift build && swift test
```

`Package.swift` is the part to be suspicious of. It now chooses its target list, product list and both
dependency lists by host, and declares two `systemLibrary` targets -- `SQLite3` and `CDBus` -- that exist
only on Linux. **The claim it rests on is that a target nothing depends on is never built**, and
`swift build` succeeding is that claim being tested. On macOS the graph should be exactly what it was
before Linux appeared in the manifest: `FacetCore` with no dependencies, the tests against `FacetApp` and
`FacetCore`, the executable product, and no `SQLite3` or `CDBus` anywhere.

**Two predictions, so a deviation is obvious rather than something to hunt for:**

- **The suite should be much faster than it was.** Each DDL file is applied in one transaction now, where
  sqlite had been giving every statement its own and an fsync with it. On Linux that took the XCTest half
  from 38.1s to 2.0s, and every database-backed test here was paying the same cost.
- **About 1750 tests, reported as two figures** -- an XCTest count and a swift-testing count -- because 17
  suites migrated. It was 1718 before; the new ones are the SHA-256, loopback listener, UUID, BlueZ object
  tree and BlueZ address suites. The `SystemBus` suite is `#if canImport(CDBus)` and compiles to nothing
  here.

**If it fails, send the output raw rather than triaging it.** A manifest mistake will be at the top, and
the Linux box would rather read the real errors than a summary of them.

## 2. Check the symlinked DDL file survives the bundle

**Why:** `database/500_timezone.sql` is a **symlink** to `002_timezone.sql` now, so the debug database's
`timezone` table cannot drift from the app's. It was verified on Linux -- SwiftPM copies it into the
resource bundle *as a link*, and it resolves because `.process` flattens the target into the same
directory -- but **macOS SwiftPM has never been asked to do it**. `502_timezone_alias.sql` and
`503_timezone_lookup.sql` are the same arrangement.

```sh
ls -l .build/arm64-apple-macosx/debug/FacetApp_FacetCore.bundle/Contents/Resources/*timezone*
ls .build/arm64-apple-macosx/debug/FacetApp_FacetCore.bundle/Contents/Resources/*.sql | wc -l
```

Wanted: whether the three arrive as links, as real files, or dangling -- and **17**, which is the file
count now. Any of the first two is fine; a dangling link means the debug database comes up without a
`timezone` table.

**If it dangles**, say so and stop there: the fix is to make those three real files again and accept the
drift risk the link removed, and that is a decision rather than a repair.

## 3. Answer question 4 in `systems-info.md`

**Why:** it is the last thing outstanding in that file's queue, it costs about a minute, and it explains
something on this machine that nobody has accounted for: `test.sqlite` had `AEST` in its `timezone`
table, which is not an IANA identifier. On Linux `TZ=AEST` is refused and falls back to the system zone,
so whatever produced it is Darwin-specific.

The probe and the exact wanted answers are in *Information required about the Mac* in
[systems-info.md](systems-info.md). **The answer goes there, in the Mac's own facts section, and question
4 is deleted in the same change** -- that file's rule, not this one's.

It matters more now than when it was asked: `timezone` is seeded with the 447 real zone names, so an
identifier like `AEST` misses the seed *and* the alias table and lands as a runtime row above id 447.

## 4. Run the scripted suite and commit the stamp

**Why:** CI is red and correct to be. The committed stamp is run 170 at `0f78510`: `outcome: failed`, 21
of 32 scripts, 11 short of their declared checks -- and twelve files have changed since it, including the
timezone seeding, `TimezoneStore` and the suite's own `lib.sh`, `51`, `53` and `56`.

**This is the one thing the Linux box can never do.** There is no app to drive here, no accessibility
tree, and `Tests/Scripted/` needs a person and a cube.

Worth knowing before starting: the cube has been factory reset and driven from Linux since that stamp
(see [linux-bluez-port-notes.md](linux-bluez-port-notes.md)), so it is on the vendor PIN, was last left
paused with auto-pause at 5 minutes, and its pairing on this Mac will need making again.

**Do this last.** It takes an uninterrupted screen and it is worth nothing if item 1 has not passed
first.
