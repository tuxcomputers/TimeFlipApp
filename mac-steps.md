# What to do on the Mac

**You are the macOS half of a two-machine piece of work.** The other half runs on Linux, where this
repository is also checked out, and it has gone as far as it can: there is no AppKit there, so
`FacetApp` cannot be compiled at all, and the change described below is mostly a conversation with the
compiler about access levels. That is why it is waiting for you.

## Read these first, in this order

1. **`CLAUDE.md`, the whole file.** Its own first rule says to, and it carries the conventions this
   change has to be made under -- the database rule, `docs/state-reference.md`, nothing fails silently.
2. **`docs/linux-port.md`** for what has been established about the port and what is still open. You
   will be writing back into this file, so know its shape before you add to it.
3. **`docs/facetcore-split.md`**, which is the actual procedure. **That file is the instructions; this
   one is only the orientation, the guardrails and where to report.** Where the two appear to differ,
   `facetcore-split.md` is right about the procedure and this file is right about when to stop.

## What to do

Work through `docs/facetcore-split.md` from the beginning.

**Do stages 1 and 2, then stop and report.** Stage 1 is three decouplings that stand on their own;
stage 2 creates the target and moves 83 files. Both are cheap to review. Stage 3 is an access-level
loop that may run to several hundred edits, and it deserves a look at the shape of the split before it
starts rather than after.

Start a branch off `feature/linuxPort` before you touch anything.

## Guardrails

- **One commit per stage.** Each must be revertable on its own. A single commit containing the whole
  exercise is neither reviewable nor bisectable.
- **`swift build && swift test` between every stage.** 1632 tests, all green, none skipped. A stage
  that leaves them red is not finished.
- **Stage 3 is compiler-driven.** Do not widen access levels speculatively. Build, fix exactly what the
  compiler names, rebuild. There are zero explicit access modifiers in `Sources/` today and guessing
  produces a far wider change than the one needed, while burying the errors that matter.
- **`package`, not `public`.** Both targets are in one package. A `package` type also needs a
  `package init` -- Swift does not widen a memberwise initialiser for you.
- **Leave the tests target alone**, beyond making it compile. Splitting it, and the swift-testing
  migration, are separate changes (`docs/linux-port.md`, to-do item 6). Do not start either.
- **Never run `Tests/Scripted/run.sh` yourself.** It drives the real mouse and keyboard on the owner's
  screen and needs a person to turn the cube. Ask, and say what you want it to prove.

## Stop and ask if

- **The compiler says a file on the 83-file move list needs AppKit.** That list was computed from
  imports on the Linux side and the compiler is the authority, not the list. It is a finding to record,
  not something to work around.
- **Stage 3 balloons.** Abandoning it is a legitimate outcome, not a failure:
  `#if canImport(AppKit)` around the platform files achieves a Linux build with no access changes at
  all, and `docs/facetcore-split.md` describes that fallback. Nothing downstream needs two targets
  specifically -- what is needed is that the portable half compiles without AppKit.
- **Anything contradicts what `docs/linux-port.md` claims.** That file is a record of measurements and
  a wrong one is worth more attention than a new one.

## Reporting back

**Write what you find into `docs/linux-port.md`, in the same commit as the work that found it.** That
file is the record the Linux side reads to know where things stand, and its own header sets the rule
this has to follow: every claim is either **measured, with a date and a machine**, or **marked
untested**. Nothing in between.

Concretely, expect to touch:

- **`## Where it stands`** -- the status table at the top.
- **To-do item 2**, which is this work. Strike it through and date it if the split lands; if you took
  the `#if canImport(AppKit)` fallback instead, say so plainly, because that changes what item 2 meant.
- **`## Found: a real module split needs ~500 access-level edits`** -- it estimates 103 types and ~511
  members from a script on the Linux side. **Replace the estimate with the real number.** That is the
  single most useful thing you can send back, because every future judgement about this change is
  currently resting on a guess.
- **`## Found: the layer boundaries are better than the file count suggests`** -- correct it if the
  compiler disagreed about which files were portable.
- **`## To check`** -- retire anything you answered, and add anything you hit that is still open.

Two specific questions the Linux side could not answer and you can:

1. **Does SwiftPM follow the symlinked resources directory on macOS?** It does on Linux, verified. If it
   does not here, the macOS app ships with no DDL and `00-setup.sh` fails loudly. It is the one real
   risk in the commit before this work, `7ade2c7`.
2. **Does the core build under Swift 6.0?** The Linux spike used 6.2, while `Package.swift` declares
   tools-version 6.0. Say which toolchain you used.

## When the whole thing is done

The scripted suite is the only thing that says the app works, and the stamp is **already stale** --
commit `7ade2c7` moved `Sources/` and `database/`, so a run is needed regardless of how this goes. One
run covers that commit and this work together. Ask the owner for it, then commit the stamp
`Tests/Scripted/run.sh` writes.

Then delete this file. It is a handoff note for one piece of work, not documentation.
