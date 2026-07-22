# Auto-Pause Arrow Stepper Checklist (Interactive)

Nothing needed. The press-and-hold acceleration gesture (both directions) and the
hold-interrupted-by-window-close case all moved to
`Tests/Bench/05b-auto-pause-arrow-stepper-checklist.md` once CGEventPost (Method: Simulate a real
click, double-click, or held press via CGEventPost, `../Methods.md`) was confirmed to drive this
control's `mouseDown`/`mouseUp` directly, including the two-independent-event-streams version of the
"hold with one hand, press a key with the other" gesture.
