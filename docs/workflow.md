# Workflow: How This App Is Meant To Be Used

[← Back to README](../README.md) · [Operation Spec](operation-spec.md) · [Database Design](database-design.md)

This document describes the intended *usage* of the app — how the device owner wants to organize
activities and faces. It's the "what and why" behind the schema; see the
[Operation Spec](operation-spec.md) for the "how" (the technical pipeline that turns a device
event into a stored record).

## Two kinds of activity

The device is used to track two different kinds of activity:

- **Recurring activities** — things like "Meetings" or "Break" that happen repeatedly and don't
  need per-occurrence detail beyond when they happened and how long they lasted.
- **Short-lived, ad-hoc activities** — things like an individual JIRA ticket number, which is
  effectively a one-off category that may only ever be used for a single time entry.

Both are just `category` rows — there's no schema distinction between a "recurring" category and
a "short-lived" one, only a difference in how long a given category stays in use.

## Faces map to categories many-to-one

A `category` can have more than one `face` pointing at it — e.g. if `face 3` and `face 6` are
both mapped to `category 5` ("Meetings"), then flipping to *either* face 3 or face 6 records a
timing segment against the same category. Concretely: a `device_event` row for `face = 3` and a
`device_event` row for `face = 6` both resolve to `category_id = 5` when their `time_entry` rows
are created — the resulting `time_entry` rows are indistinguishable by category, only the
underlying `device_event.face` value (and, transitively, which physical face was flipped) tells
them apart.

## Editing a face's category

When editing which category a face belongs to, the UI offers two distinct buttons — **New** and
**Rename** — that behave differently depending on whether the entered category name already
exists elsewhere:

**New** — points the face at the category with the entered name, without touching that
category's name anywhere else it's used:
- Name doesn't exist yet → create a new `category` row, assign its `category_id` to the face.
- Name already exists → don't create anything; just assign the existing category's `category_id`
  to the face (the face now shares that category with whatever other faces already point at it).

**Rename** — renames the category the face is *currently* assigned to (or assigns a fresh one if
the target name doesn't exist):
- Name doesn't exist yet → create a new `category` row, assign its `category_id` to the face
  (same outcome as **New**'s "doesn't exist" case).
- Name already exists → update that existing category's `name` in place; the face's
  `category_id` doesn't change, since it's already pointing at that row.

The practical difference between the two buttons only shows up when the entered name matches an
*existing, different* category: **New** re-points the face to share that other category (leaving
its name and every other face pointing at it untouched), while **Rename** overwrites that
category's name (affecting every other face already sharing it) instead of switching this face
to point elsewhere.
