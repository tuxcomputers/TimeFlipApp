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

## 5. Reorder `deliver` behind the send in the `Network` half of `GoogleLoopbackListener`

**Your item 1 is answered and your reading of it holds.** `swift test --filter GoogleLoopbackListenerTests`
passes on Linux, all five tests, five consecutive runs with nothing recorded -- Swift 6.2 on
`x86_64-unknown-linux-gnu`, this branch at `51d8c22`, clean tree. So the expectations are right and
`GoogleOAuthRules.redirectResponse` is right: the sockets half answers a real `URLSession` request with a
body carrying `Facet is connected.` and `Facet is not connected.`, through the same shared function the
Network half calls. What is left is the Darwin path.

**The two halves differ by more than the write loop, which is worth having before you patch it.** The
sockets half does not merely finish writing first, it puts a queue hop between the response and the
delivery:

```swift
write(connection, Data(GoogleOAuthRules.redirectResponse(body).utf8))
queue.async { self.deliver(result) }
```

`write` loops until the whole `Data` is down the descriptor, `deliver` is scheduled rather than called, and
`handle`'s own `defer { close(connection) }` closes the descriptor after `write` has returned. Nothing can
cancel that connection out from under the response. The Network half calls `deliver` synchronously on the
same serial queue the `.contentProcessed` completion would be dispatched on, and `deliver` cancels every
connection in `connections` -- this one among them -- so the pending send is discarded before its completion
can run.

**The shape that matches the other half is to deliver from the completion**, rather than beside it:

```swift
connection.send(
    content: Data(GoogleOAuthRules.redirectResponse(body).utf8),
    completion: .contentProcessed { [weak self] _ in
        connection.cancel()
        self?.deliver(result)
    }
)
```

`.contentProcessed` arrives on `queue`, which is where every mutable field in that class is already touched,
so this needs no other change to keep the `@unchecked Sendable` claim true.

**Written here rather than applied, because this box cannot compile the `#if canImport(Network)` branch at
all** -- the patch above is untested by definition, and your item asked for eyes rather than a quick patch.
What would settle it is the same two tests going green on the Mac.

**Worth checking a real sign-in as well as the suite.** If the diagnosis is right the bug was never only a
test: Google redirects back, the app takes the code, and the browser is left on an empty tab.
