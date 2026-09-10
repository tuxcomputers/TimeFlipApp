# Handover: for the Linux box

[← Back to README](../README.md) · [The other direction →](handover-mac.md) · [The two systems →](systems-info.md)

**This file is for the Linux box to act on. Everything in it is written by the Mac.**

Its mirror is [handover-mac.md](handover-mac.md), which the Linux box writes and the Mac acts on. Neither
machine edits the file addressed to itself except to delete from it, and neither deletes from the file it
wrote.

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
   information about the Linux* in [systems-info.md](systems-info.md); something the hardware does goes
   in [timeflip2-firmware-observations.md](timeflip2-firmware-observations.md); something about the port
   goes in [linux-port.md](linux-port.md), and the D-Bus mechanics in
   [linux-bluez-port-notes.md](linux-bluez-port-notes.md). This file is the asking, and it is meant to
   empty.
4. **An item you cannot do stays put, with a line saying why.** That is an answer too, and a more useful
   one than silence -- but say it in the item rather than deleting it, so whoever asked can decide what
   to do instead.
5. **Numbers are labels and are never reused.** A gap means an item was finished. A new item takes the
   next number never used before, so a commit message saying "handover 3" still means the same thing
   years later.
6. **When you have done everything you can, write what you want back.** Add items to
   [handover-mac.md](handover-mac.md) for the other machine. A blank file on both sides is the finished
   state.

## What this is not

**Not `systems-info.md`'s queues.** Those two sections ask for *facts about a machine* -- what compiler,
which filesystem, where the data directory resolves -- and the answer is written into that machine's own
facts section. This file asks for *work*: build something, run something, decide something. A question
whose answer is a fact belongs there; a task belongs here.

**Not the to-do list in `linux-port.md`.** That is what the port needs doing, in dependency order, by
whichever machine gets to it. This is what the *other* machine is being asked for, which is a much
shorter list and one that empties.
## 15. Your BlueZ files moved out of the core, unaltered, and the manifest moved with them

**The Mac is being brought into the model in `CLAUDE.md` under *The core is platform-blind, and every platform
capability is a port*, and the instruction was to move any Linux code out of the core without altering it.** Six
files went from `Sources/FacetCore` to `Sources/FacetLinux`: `SystemBus`, `BlueZRadio`, `BlueZGatt`, `DBusValue`,
`BlueZObjectTree` and `BlueZAddress`.

**The only edit to any of them is one line.** Four now say `import FacetCore`, because they use `ScannedDevice`,
`DeviceScanRules`, `TimeFlipUUIDs` or `CubeRadio` and those are outside their module now. Nothing else was
touched: no logic, no comments, no guards. `SecretToolStore` moved the same way and got the same one line, and
its `#if !canImport(Security)` was briefly removed and then put back, because removing it was an alteration and
the instruction said not to.

**`TimeFlipUUIDs` deliberately stayed in the core.** Both platforms use it and its CoreBluetooth half is already
split off into `FacetMac`, so it is not Linux code.

**Two things changed that you will meet.**

- **`Package.swift`: the Linux test target now depends on `FacetLinux`.** It has to, since the suites covering
  those six reach a module that is no longer `FacetCore`. Testing an executable target is what the macOS half
  already does with `FacetMac`, so this should be ordinary, but it is a manifest change on your side of the fence
  and worth knowing about before you pull.
- **`BlueZAddressTests` and `BlueZObjectTreeTests` are now wrapped in `#if canImport(CDBus)`** and import
  `FacetLinux`. `SystemBusTests` was already wrapped and only gained the import. On macOS those 15 tests compile
  to nothing, which is not a loss: they test code that is not built there. **On Linux they should run exactly as
  before, and that is the thing to check.**

**None of this is verified on Linux and cannot be from here.** `FacetLinux` is not in the package on macOS, so
those six files were not compiled by anything after the move. `swift build && swift test` on your side is what
says the four added imports are right and the manifest change works. **If it does not build, the fix is yours to
make and this item stays put with a line saying what broke** rather than being worked around here.

**What this does not touch**: the radio port still does not exist, so `BlueZRadio` conforms to nothing and has no
caller, exactly as before. It has simply stopped being in the circle. Candidate 1 of
`docs/architecture-review-2026-09.md` is still the piece that gives it something to conform to.

