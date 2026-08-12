# Device Rename Checklist

### Last run - 2026-08-12 16:32 on the branch 'feature/dailyLimit'

Nothing needed.

Renaming needs the cube, but never a hand on it. Every step is a click or a keystroke in the
Settings window and a BLE write the app makes on its own, so the whole thing lives in
`Tests/Bench/09b`. The device only has to be switched on and in range.

The one part that looked like it needed a person was the **right-click menu** on the Name row, which
is invisible to accessibility. It is driven by coordinate instead, the same way the Categories tab's
rename already was: see [Method 26](../Methods.md#method-26).

That method grew two things for this checklist, both worth knowing before assuming a right-click
step is broken:

- `anchor_dx`, for the bare middle of a `LabeledContent` row, which belongs to the row's hit area
  and to no accessibility element.
- The finding that a **selectable** value takes the right-click before SwiftUI ever sees it, and
  answers with macOS's "Look Up" menu. The Device tab's name needed `.textSelection(.disabled)`
  before its own menu would open at all.
