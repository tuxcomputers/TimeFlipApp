# CI tests for the Categories tab

**All written except 22 and 23**, which are commented out in place until `time_entry` has a writer.
`CategoryStoreTests` (1-24), `CategoryEditRulesTests` (25-43) and
`Workflows/W09-category-lifecycle` (44-49). This file is kept as the map of what is covered and
why, and as the record of what was deliberately left to a checklist.

CI here means the hermetic `swift test` suite (XCTest plus the swift-testing workflow suites),
never the on-device checklists under `Tests/`.

The tab's behaviour splits three ways, and the split matters more than the individual tests:

- **Store writes** are reachable today. `AppDataStore`'s category methods take plain arguments and
  hit a real SQLite file, so `TestDBPaths` covers them with no new seams.
- **Decision logic is reachable now.** Name collisions, the rename confirmation, the icon toggle,
  the daily-limit clamp and the Active partition were all `private` on SwiftUI views, pure but
  uncallable. They live in `CategoryEditRules` as of this branch. See
  [Extracted decisions](#extracted-decisions).
- **Presentation is out of scope** and belongs on a checklist. See [Not CI material](#not-ci-material).

## Already covered

Not to be redone. Listed so the gaps below read as gaps rather than as the whole surface.

| Area | Where |
|---|---|
| Name normalisation (trim, collapse, punctuation kept) | `CategoryNameNormalizationTests` |
| Display order (numeric, natural, case, tie-break by id) | `CategoryDisplayOrderTests` |
| `createCategory` returns the new id / rejects empty / duplicates insert a second row | `CategoryCreationAssignmentTests` |
| Assigning a new category to a face, and refusal on a locked face | `CategoryCreationAssignmentTests` |

## Store writes and reads

`CategoryStoreTests`, against a real seeded database in a temporary directory.

**`loadCategories`**

1. Excludes the `Unassigned` sentinel at `category_id` 0.
2. Returns inactive rows as well as active ones, since the tab renders both sections from this one
   read.
3. Returns rows in `displayOrder`, not rowid order. Seed out of order so insertion order and sorted
   order genuinely differ.
4. On a fresh database returns exactly the seeds, `Break` and `Meeting`. Written this way rather
   than as an empty case, which would need the seeds deleted first: the seeds are what the Faces
   tab's default assignments point at, so pinning them catches a change that would silently alter a
   new install.

**The `category_id >= 1` guard.** Every writer carries it, and each needs its own test: a write
aimed at the sentinel must leave it untouched.

5. `updateCategoryName` refuses id 0.
6. `updateCategoryColour` refuses id 0.
7. `updateCategoryIcon` refuses id 0.
8. `updateCategoryActive` refuses id 0, so `Unassigned` can never be retired.
9. `updateCategoryDailyLimit` refuses id 0.

**Individual writers**

10. `updateCategoryName` changes `category_name` and leaves icon, colour, active and limit alone.
11. `updateCategoryName` rejects an empty name rather than storing one.
12. `updateCategoryColour` stores `colour_id`, including 0 for the None colour.
13. `updateCategoryIcon` stores `icon_id`, including 0. Icon 0 is how the grid clears a selection,
    so it is a real value and not a failed write.
14. `updateCategoryActive` sets and clears, and only ever writes 0 or 1. The column has a `CHECK`
    constraint, so a wrong value fails the write rather than storing something odd.
15. `updateCategoryDailyLimit` stores whole minutes, with 0 meaning disabled.
16. `updateCategoryDailyLimit` clamps a negative to 0. The clamp is in the SQL bind, so it holds
    even for a caller that skipped the view's own clamp.
17. Every writer is a silent no-op against a `category_id` that does not exist: no crash, no other
    row touched.

**`findCategory`**

18. Matches `COLLATE NOCASE`, so "meeting" finds "Meeting".
19. Finds the `Unassigned` sentinel, unlike `loadCategories`. Typing that name has to be reported
    as a collision rather than silently inserting a second one.
20. Returns `nil` for an empty name.
21. With two rows sharing a name (legitimate, per the create flow), prefers the **active** one,
    and falls back to the oldest when every match is retired. **A failure here is a real bug, not a
    bad test**: both collision paths ask this question and act on the answer.

**One active category per name (`UN1_category`).** Added after the tests above, when the partial
unique index went in. See `docs/database-design.md` for why the index is partial.

21a. A second *active* category cannot take an active name.
21b. The name is taken case-insensitively, matching `findCategory`.
21c. Any number of *inactive* categories may share a name.
21d. One active may sit alongside its retired namesakes.
21e. Reinstating succeeds when no active category holds the name.
21f. Reinstating is refused, and reports it, when one does. The case that makes
     `updateCategoryActive`'s return value necessary: the tab patches rather than re-reads, so a
     refusal reported as success would tick the box over a row that is still retired.
21g. Retiring is never refused. The index only constrains active rows, so leaving is always
     possible even when coming back would not be.

**Cross-table**

22. **Deferred, commented out in `CategoryStoreTests`.** Retiring a category leaves its
    `time_entry` rows resolvable. The entire stated reason for `active` existing instead of a
    delete.
23. **Deferred, commented out in `CategoryStoreTests`.** Renaming a category changes what
    historical rows report, since everything links by `category_id`. The behaviour the confirmation
    dialog warns about.

Both are waiting on a real writer and reader for `time_entry`. The raw-SQL version passed but only
showed that SQLite joins on a foreign key, with no app code putting the row there or reading it
back. Reinstate them, and the raw SQL helpers at the foot of that file, when the table is live.
24. Retiring a category still assigned to a face leaves the face assignment intact. The Faces tab
    filters retired categories out of the *assignment list*, which is not the same as clearing an
    assignment already made.

## Extracted decisions

All of these now live in `Sources/TimeFlipApp/CategoryEditRules.swift`, moved out of the views
without changing what they decide. Each test below is a plain call with no SwiftUI involved.

The two collision cases carry both the matched row and the typed name, because they are not
interchangeable: the lookup is `COLLATE NOCASE`, so "meeting" collides with "Meeting", and the
alert names the row that exists while the debug line records what was typed.

**Create-name collision** (`CategoryEditRules.createDecision`)

25. A free name inserts, with no alert.
26. A name held by an active category is a dead end offering no create.
27. A name held by an inactive category offers exactly two real choices, reactivate or create a
    duplicate, plus cancel.
28. The name is normalised before the lookup, so trailing space cannot dodge a collision.

**Rename collision** (`CategoryEditRules.renameDecision`)

29. An unchanged name leaves edit mode with no confirmation raised.
30. A name that normalises to empty does the same.
31. A case-only change on the row being renamed is *not* a collision. `findCategory` is
    `COLLATE NOCASE`, so the row finds itself, and the `existing.id != category.id` check is the
    only thing preventing a false collision. Directly worth a test.
32. Colliding with an active category is a dead end.
33. Colliding with an inactive one offers rename-anyway.
34. A free name raises the plain history warning.

**Icon grid** (`CategoryEditRules.iconSelection`)

35. Clicking an unselected icon yields its `icon_id`.
36. Clicking the already-selected icon yields 0, which is how clearing works with no None cell in
    the grid.

**Daily limit** (`CategoryEditRules.dailyLimitWrite`)

37. A negative input clamps to 0.
38. An unchanged value writes nothing. Guards a redundant write and a misleading `debug_log` line.

**List partition and patch-in-place** (`CategoryEditRules.partitioned` / `.patching`)

39. Unticking Active moves a row from the Active partition to the Inactive one with no re-read.
40. Ticking it in the Inactive section moves it back.
41. `patch` updates only the row it names and leaves the rest of the list identical.
42. `patch` against an id not in the list is a no-op.
43. `CategoryRecord.with(...)` replaces exactly the named field and never the id. Every edit on the
    tab funnels through it, and it had no test at all.

## Workflow suite

`W09-category-lifecycle`, an ordered suite in the style of the existing `W0*` files. The tests above
each prove one write or one decision; this proves that they compose. Reinstating goes through
`createDecision` rather than calling the store directly, because typing a colliding name is the only
way to reach it in the app.

`time_entry` survival is left to test 22 rather than repeated here, for the raw-SQL reason above.

44. Create a category, confirm it lands active with no icon, no colour and no limit.
45. Assign it to a face and confirm the face resolves to it.
46. Rename it and confirm the face assignment still resolves, now under the new name.
47. Give it a daily limit and a colour, then retire it.
48. Confirm it leaves the Faces tab's assignment list while its existing face assignment and its
    history both still resolve.
49. Reactivate it through the create-collision path and confirm it returns with its colour, limit
    and history intact, rather than as a fresh row.

## Not CI material

Belongs on a Bench or Interactive checklist, for the reasons in
`Tests/TimeFlipAppTests/Workflows/README.md`.

- The right-click context menu that opens Edit.
- Popover presentation for the colour and icon pickers.
- Alert presentation and button roles.
- Field focus after the deferred `DispatchQueue.main.async`, and Escape backing out of both the
  rename and the create field.
- The Escape shortcut handover with the window's Close button (`AppState.openCategoryNameFields`).
- Disclosure state, column alignment and anything else visual.
