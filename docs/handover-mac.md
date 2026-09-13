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

## 15. Candidate 1 of the architecture review: put the radio seam below the sequencing

**Yours because this box cannot compile the files it rewrites.** `swift build --target FacetMac` here answers
`error: no target named 'FacetMac'` -- the Linux graph has no such target -- so `BluetoothRadio.swift` is a
file I can neither build nor test, let alone drive against a cube. The candidate itself is written out in
[architecture-review-2026-09.md](architecture-review-2026-09.md) with the five clusters, the budgeted-twice
argument and a *what it must not break* section; this item is what has changed around it rather than a
restatement.

**Four of the five clusters are done and this item is trimmed to the fifth (Mac, 2026-09-13).** The command
channel, the PIN rotation machine and the history fetch went with `DeviceLogin` into `FacetCore`; the reset
proof followed as `CubeResetProof`. **What is left is the reach and candidate order**: `ReachTarget`'s eight
fields and `beginTryingWhatWasFound`, `tryNextCandidate` and `endReach`, about 84 lines in `BluetoothRadio`.
`DeviceScanRules.reachOrder` is already core; what is still here is the loop that drives it, the queue, the
not-tried-twice set, `anyRefused` telling "none of them was ours" from "nothing was there", and
`windowWasCutShort` paying for the shortcut when the remembered cube turns up early and then refuses the PIN.
Everything deleted from this item above was either done, or a prediction that has since been confirmed.

**And the part I cannot help with at all**, which still stands for the cluster that is left. The reach is the
reconnect path, and the device rename is the precedent nobody wants repeated: green everywhere and the cube
unreachable on the next launch, because reconnecting is a scan and nothing in `swift test` scans. Four device
scripts cover it, so it cannot be confirmed without a cube and a person.

*(The two measured `0x10` traps this used to warn about are no longer in the code being moved: both live in
`DeviceLogin` in `FacetCore` and have had tests since 2026-09-10. Mac, 2026-09-13.)*

