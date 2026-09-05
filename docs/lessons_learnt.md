# Lessons learnt while developing the Facet app

## Multiple CLAUDE.md files

I used to have just a single CLAUDE.md in the root of the repo. While doing this project I split it: the root file
holds the conventions that apply everywhere, and a second one sits beside the thing it governs. Today that is
`database/CLAUDE.md`, next to the DDL, holding the naming and storage rules and the schema-change procedure. The root
file references it, so a task that touches the schema is pointed at it rather than having to already know.

The pattern generalises. The previous test suite's own `CLAUDE.md` did the same job: the root file said
when to read it, which was any task to do with testing.

## Rule number 1

The first rule in every instruction file is to read the whole file before taking any action. There were times Claude
decided it had enough to complete the task and did not obey rules further down the file.

## Add a methods file

While getting Claude to implement the scripted tests it was using various techniques to implement the same test step.
Watching it, I could see it doing the same trial and error for the same task (clicking a menu, say) again and again. I
had it create a file holding the *methods* of achieving a task. A step that needs to do that thing links to the
numbered method. When a better method is discovered, the methods file is updated and every step referencing it gets
the better one for free.

That file is `Tests/Methods.md`. It has earned its place several times over: it records what needs a real mouse event
and what does not, why a status item is not in `AXMenuBar`, and the two reasons `performClick` silently does nothing.
A technique rediscovered is a technique that was written down too late.

## Documentation

I had Claude document my stream-of-consciousness thoughts as I had them. Different documents for different purposes:
operations, database design, installation. I would say "here is an idea I just had, make sure you add it to the
correct documentation".

The thing I underestimated is that documentation rots the moment the code moves under it, and it rots invisibly: a
doc naming a class that no longer exists still reads perfectly well. Worse, it gets read and believed. `docs/rebuild.md`
carrying a "still to do" list of features that had shipped is the version of this that cost the most, because it is
the file somebody would go to precisely to find out what was left. It was deleted once the rebuild was finished, which
is the other half of the lesson: a document with a job that has ended does not become harmless, it becomes wrong.

## Checklists

A subset of the documentation was TODO lists tracking processes not yet complete. On this project one was the removal
of legacy code: I had completely redesigned how the app operates, with all settings and data in a SQLite file, so I
had Claude inspect the design documents, look at how the legacy code operated, and produce a TODO file for removing
it.

These lists are a good way to track what still needs doing and what is finished. The other half of that, which I only
learnt afterwards: **delete one when it is done**. Three of them survived the thing they were tracking and became
inventories of an implementation that no longer existed, which is worse than having no list at all -- an unticked box
in a live list means work outstanding, and an unticked box in a dead one means nothing whatsoever, and the two look
identical.
