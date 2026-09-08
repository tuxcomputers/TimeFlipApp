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
