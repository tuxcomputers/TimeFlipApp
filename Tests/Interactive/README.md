# Interactive Test Checklists

The human-in-the-loop half of the device tests: every `(You)` step here needs a real person -- a
physical action on the cube (facet flip, double-tap), a sustained press-and-hold mouse gesture
(System Events can click a control but not hold a mouse button down over time), a status-item
gesture unverified via script (see "Status-item click gesture" in `../Methods.md`), or multiple
elements that must be confirmed changing in lockstep with each other -- a claim two screenshots
can't establish on their own (see "Screenshot-based visual confirmation" in `../Methods.md`).
**This suite runs after** `Tests/Bench/`, which drives everything Claude can do unattended against
a connected device -- including, now, most menu/button clicks, text entry, and single-value
time-based checks (a DB value increasing, or two time-spaced screenshots/reads), so this folder is
narrower than "needs a human's hands or eyes" once implied.

A step belongs here when it needs a human for one of the reasons above. Where a numbered checklist
has no interactive-side work, its file here is a stub containing just `Nothing needed` (e.g.
`06`/`07`, which are fully Claude-drivable). `04`'s menu-only and DB-verifiable scenarios moved to
`Tests/Bench/` once menu clicks were verified working and "is the time increasing?" was converted
to a DB check -- what's left here is only what still needs the status-item gesture or a physical
flip; see that file's intro for the split.

For how to run these -- the two-phase order, `(Claude)`/`(You)` step tags, the test-database switch,
reading `debug_log`, the file-numbering convention, recording bugs, and CI enforcement -- see
[`../CLAUDE.md`](../CLAUDE.md), which holds everything common to both suites. For the concrete
mechanics behind a `(Claude)` step, see [`../Methods.md`](../Methods.md).
