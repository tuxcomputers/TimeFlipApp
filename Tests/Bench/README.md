# Bench Test Checklists

The entirely-Claude half of the device tests: checklists run end-to-end against a connected device
-- launch/quit the app, edit the DB, drive Preferences-window and status-item-menu controls via
System Events, wait on timers, and assert from `debug_log`/`device_events`. No human hands or eyes
required beyond a powered, in-range cube. **This suite runs first**, before `Tests/Interactive/`.
Since every step here is Claude's, items carry no actor label (see `../CLAUDE.md`'s Format section).

A step belongs here when Claude can perform it -- i.e. it is *not* a physical cube action, a
sustained press-and-hold mouse gesture, or a time-based visual confirmation (a blink/flash watched
over a couple of seconds) that a single screenshot or accessibility read can't capture. Where a
numbered checklist has no bench-side work, its file here is a stub containing just `Nothing needed`.

For how to run these -- the two-phase order, the `(Claude)`/`(You)` step tags used in
`Tests/Interactive/`, the test-database switch, reading `debug_log`, the file-numbering convention,
recording bugs, and CI enforcement -- see [`../CLAUDE.md`](../CLAUDE.md), which holds everything
common to both suites.
