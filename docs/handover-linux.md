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

---

## 1. `GoogleLoopbackListenerTests` fails on macOS, on the `Network` path only

**Why:** it is the only thing red in `swift test` on this branch, it is one of the suites that migrated
to swift-testing, and the Darwin half of `GoogleLoopbackListener` is code the Linux box has never been
able to run. Measured 2026-09-08 on the merge of `main` into this branch, deterministic over four runs:

```
✘ theCodeArrivesAndTheBrowserIsToldItWorked() recorded an issue at
  GoogleLoopbackListenerTests.swift:57:9: Expectation failed:
  (body?.contains("Facet is connected.") -> nil) == true
✘ aRefusalArrivesAsDeniedAndSaysSo() recorded an issue at
  GoogleLoopbackListenerTests.swift:69:9: Expectation failed:
  (body?.contains("Facet is not connected.") -> nil) == true
```

Everything else in the suite passes, and so does everything else in the package: 1392 XCTest and 357 of
359 swift-testing.

**The parsing is fine and the redirect is fine.** Both tests assert `redirect == .code("the-code")` and
`redirect == .denied("access_denied")` on the line above the failing one, and both of those pass. What is
nil is the HTTP body reaching the client. So the listener accepts, reads the request line, resolves the
right `Redirect` and hands it to whoever is waiting; the response just never arrives.

**Not triaged into a fix, because item 1 of `handover-mac.md` asked for the output raw.** But the
ordering worth looking at first is in `accept(_:)` under `#if canImport(Network)`, and it is a real
difference between the two implementations rather than a guess:

```swift
connection.send(
    content: Data(GoogleOAuthRules.redirectResponse(body).utf8),
    completion: .contentProcessed { _ in connection.cancel() }
)
self.deliver(result)
```

`send` is asynchronous and `.contentProcessed` has not fired yet when `deliver(result)` runs on the same
queue, and `deliver` cancels the listener and then every connection in `connections`. The Berkeley
sockets path does not have this shape: its `write(_:_:)` loops until the whole `Data` has gone down the
descriptor before anything else happens, so the same ordering is harmless there.

**If that reading is right it is not only a test failure**, which is why it is worth your eyes rather
than a quick patch here: it would mean a real sign-in on macOS leaves the browser on an empty tab after
Google redirects back, with the app itself having taken the code correctly.

**What would settle it:** whether these two tests pass on Linux. If they do, the suite is fine and the
Darwin path is wrong; if they fail there too, the expectation or `redirectResponse` is.

