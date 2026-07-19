# Bench Test Checklists

The script-drivable half of the device tests: checklists a UI-automation harness can run end-to-end
against a connected device -- launch/quit the app, edit the DB, drive Preferences-window controls,
wait on timers, and assert from `debug_log`/`device_events`. No human hands or eyes required beyond a
powered, in-range cube. **This suite runs first**, before `Tests/Interactive/`.

A step belongs here when a harness can perform it -- i.e. it is *not* a physical cube action, a
status-item gesture/menu click, or a visual confirmation of the custom-drawn menu-bar status item.
Where a numbered checklist has no bench-side work, its file here is a stub containing just
`Nothing needed` (e.g. `04`, which is entirely interactive).

For how to run these -- the two-phase order, `(Claude)`/`(You)` step tags, the test-database switch,
reading `debug_log`, the file-numbering convention, recording bugs, and CI enforcement -- see
[`../CLAUDE.md`](../CLAUDE.md), which holds everything common to both suites.
