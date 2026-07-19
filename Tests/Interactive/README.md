# Interactive Test Checklists

The human-in-the-loop half of the device tests: every `(You)` step here needs a real person -- a
physical action on the cube (facet flip, double-tap), a status-item gesture or status-**menu** click,
or a visual confirmation of the custom-drawn menu-bar status item (a badge, an icon, a blink) that
isn't machine-readable. **This suite runs after** `Tests/Bench/`, which drives everything a harness
can do against a connected device.

A step belongs here when it needs a human's hands or eyes. Where a numbered checklist has no
interactive-side work, its file here is a stub containing just `Nothing needed` (e.g. `06`/`07`,
which are fully script-drivable). `04` is the reverse -- all its work is here, so its Bench
counterpart is the stub.

For how to run these -- the two-phase order, `(Claude)`/`(You)` step tags, the test-database switch,
reading `debug_log`, the file-numbering convention, recording bugs, and CI enforcement -- see
[`../CLAUDE.md`](../CLAUDE.md), which holds everything common to both suites.
