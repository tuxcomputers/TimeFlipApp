# Leasson learnt while developing the TimeFlip app

## Multiple CLAUDE.md files
I used to have just a single CLAUDE.md file inthe root of the repo. While doig this project I 
changed and created multiple CLAUDE.md files. The root CLAUDE.md file references the other files
and what each purpose each file serves.

An example, there is a CLAUDE.md file in the Tests folder. The main CLAUDE.md file has instructions
when to read that file ie when it is doing any task related to testing.

## Rule number 1
The first rule in all the instruction files is to read the entire file before taking any action.
There were times that Claude considered it had enough to complete the task and did not obey rules
in the isntruction file.

## Add a methods file
While getting Claude to implement the scripted testing it was using various techniques to implement
the test step. As I watched it would do the same trial and error for the same task (eg click a menu)
again and again. I had it create a file that contained the methods of achieving a task. When a step
in the test script needed to do the same thing it would link to the numbered method. If a new better
method was discovered then the methods file was updated, all of the steps that reference the method
then use the better method.

## Documentation
I had Claude document my stream of conscienceness thoughts as I had them. I created different documents
for different purposes, operations, database design, installation. I would tell Claude 'here is an idea
I just had, make sure you add it to the correct documentation'

## Checklists
A subset of the documentation was TODO list related to various processes that were yet to be completed.
An exampel on this project was the removal of Legacy code. I have completely redesigned the way this app
operates, all of the settings and data are now in a SqLite DB file. I had Claude inspect the design
documents, how the legacy code operated and create a TODO file related to removing the legacy code.

These TODO list and a good way to track what still needs to be done and what you have completed.

