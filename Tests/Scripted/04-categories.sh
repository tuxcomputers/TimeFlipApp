#!/bin/bash
# The Categories tab: creating one, renaming it, retiring it, and bringing it back.
#
# Everything below this script depends on a category existing, since a face holds one and a time entry is
# filed under one. It runs before them for that reason.
#
# **The categories it makes are numbered and left behind.** `next_name` reads the highest `Scripted N`
# already there and goes one past, so a clean database starts at `Scripted 1` and a `--keep` run that
# already holds seventeen starts at `Scripted 18`. An active name has to be unique, and nothing here
# deletes what it made, because the rows are the evidence.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "creating, renaming, retiring and reinstating a category"

open_settings
select_tab Categories

NAME=$(next_name Scripted)
RENAMED="$NAME renamed"

# Turns a category's name into an editable field, and waits until it really is one.
#
# **A fixed sleep loses this race.** A refused rename reloads the whole list, so the row is briefly a view
# on its way out and the press lands on nothing -- which is what happened on 2026-08-16: the cell was
# still a button when the field was written to, so nothing committed and the app logged nothing at all.
# **The cell may already be editing**, so this opens it if it is not and waits either way. A refused
# rename leaves the field open holding the name that was rejected -- the `.refuse` branch returns before
# `reloadSelectedPane()`, unlike every other rename outcome -- so the button is hidden and pressing it does
# nothing. That is why the value is written with `set_field_focused`: nothing has called
# `makeFirstResponder` in that case, and a Return posted at an unfocused field commits nothing at all.
begin_rename() {
    press "category-name-$1"
    wait_for_element "category-name-$1-field" 5
}

# ---------------------------------------------------------------------------- the two sections
#
# **First, before anything expands the Inactive one.** Its collapsed state is only observable until this
# script opens it to look at a retired row, so a check placed further down would be reading its own doing.
# The archive tested this too (`08b` setup, Step 3).

check_contains "the Active section is on the tab" "$(tree)" "id=categories-active-section"
check_contains "and the Inactive section is too" "$(tree)" "id=categories-inactive-section"

# Active opens expanded and Inactive opens folded, because one is the list somebody came to use and the
# other is a record they came to consult. Read off the rows rather than off the heading: a section with
# its contents showing is what expanded means.
check "the Inactive section starts folded" "0" "$(tree | grep -c "id=retired-category-name-" || true)"

# ---------------------------------------------------------------------------- what Save will not create
#
# **Nothing typed is not an error and not an alert, it is nothing done.** The rule answers `ignore` for it
# (`CategoryCreateRules.decision`), and whitespace normalises to empty before that -- so a trailing space
# cannot slip a duplicate past the checks that follow, and a field of spaces cannot make a category whose
# name nobody can see or type again.

before_count=$(sql "SELECT COUNT(*) FROM category;")

press create-category
sleep 0.5
check_contains "pressing Create opens a name field" "$(tree)" "id=category-name-field"

press save-category
sleep 0.8
check "saving an empty field creates nothing" "$before_count" "$(sql "SELECT COUNT(*) FROM category;")"

press create-category
sleep 0.3
set_field category-name-field "   "
press save-category
sleep 0.8
check "and neither does a field of spaces" "$before_count" "$(sql "SELECT COUNT(*) FROM category;")"
check "with no alert raised for either" "no" "$(alert_is_open && echo yes || echo no)"

# ---------------------------------------------------------------------------- create

since=$(mark)
press create-category
sleep 0.5
set_field category-name-field "$NAME"
press save-category
sleep 1

expect_log "a typed name is saved as a new category" "$since" "%Save new category \"$NAME\"%"

# The id it was given, from the app's own line, so everything below addresses the row that was just made
# rather than guessing which one it is.
ID=$(sql "SELECT message FROM debug_log WHERE debug_log_id > $since AND message LIKE '%Save new category%' ORDER BY debug_log_id LIMIT 1;" | sed -E 's/.*category_id ([0-9]+).*/\1/')
if [ -n "$ID" ]; then
    pass "the new category has an id ($ID)"
else
    fail "the app did not report a category id, so the rest of this script cannot address it"
    finish
    exit 1
fi

check "the table holds it, active" "1" "$(sql "SELECT active FROM category WHERE category_id = $ID;")"
check "under the name that was typed" "$NAME" "$(sql "SELECT category_name FROM category WHERE category_id = $ID;")"

# On screen as well as in the table. A row written and not drawn is the case a table-only check misses.
check_contains "its row is on the tab" "$(tree)" "id=category-name-$ID"

# ---------------------------------------------------------------------------- rename
#
# The name is a button that becomes a field, and Return commits it -- see Tests/Methods.md Method 10.
# Setting the value alone fills the field and commits nothing, which is why the key is posted.

since=$(mark)
begin_rename "$ID"
set_field_focused "category-name-$ID-field" "$RENAMED"
press_return
sleep 1

expect_log "committing a new name asks first" "$since" "%rename -> \"$RENAMED\", asking%"
check "nothing is renamed until the question is answered" "$NAME" "$(sql "SELECT category_name FROM category WHERE category_id = $ID;")"

since=$(mark)
press_title Rename
sleep 1
expect_log "answering Rename does it" "$since" "%Rename \"$NAME\" -> \"$RENAMED\"%"
check "the table holds the new name" "$RENAMED" "$(sql "SELECT category_name FROM category WHERE category_id = $ID;")"

# The id is what history hangs off, and a rename that made a new row would strand every entry recorded
# against the old one. This is the property the confirmation sheet spends a paragraph explaining.
check "and it is the same row, not a new one" "1" "$(sql "SELECT COUNT(*) FROM category WHERE category_id = $ID;")"

# ---------------------------------------------------------------------------- retire

since=$(mark)
press "category-active-$ID"
sleep 1
expect_log "unticking Active retires it" "$since" "%\"$RENAMED\" retired%"
check "the table says inactive" "0" "$(sql "SELECT active FROM category WHERE category_id = $ID;")"

# It leaves the active list rather than sitting in it greyed out, and appears under Inactive.
#
# **Matched on `id=category-name-N`, not on `category-name-N`.** The retired row is
# `retired-category-name-N`, which contains the shorter string, so a loose match finds the row in the
# other list and reports the category as still active when it has moved.
check "it is gone from the active table" "0" "$(tree | grep -c "id=category-name-$ID" || true)"

# The Inactive section folds away, so it has to be opened before its rows are anywhere to be found. The
# whole heading is the target, not just the triangle.
if ! tree | grep -q "retired-category-name-$ID"; then
    press categories-inactive-section-heading-button
    sleep 1
fi
check_contains "it is listed under Inactive" "$(tree)" "id=retired-category-name-$ID"

# ---------------------------------------------------------------------------- reinstate

since=$(mark)
press "retired-category-active-$ID"
sleep 1
check "ticking it there brings it back" "1" "$(sql "SELECT active FROM category WHERE category_id = $ID;")"
check_contains "and its row is back on the active table" "$(tree)" "id=category-name-$ID"

# **A retired category keeps everything.** Nothing above deleted a row, which is the point of retiring
# rather than deleting: every time entry filed against it still resolves.
check "its name survived the round trip" "$RENAMED" "$(sql "SELECT category_name FROM category WHERE category_id = $ID;")"

# ============================================================================ retired namesakes
#
# Typing a name a *retired* category already holds. The database allows it -- only active names are
# unique -- so there are two legitimate answers and the app asks rather than choosing: bring the old one
# back and keep its history, or make a new one and leave that history where it is.
#
# **How many retired namesakes there are changes what can be offered.** With one there is an "the old
# one" to reactivate; with several there is not, and Reactivate is withdrawn rather than picking blind.
# That absent button is the point of the second half below, and it is why these read the alert's buttons
# off the sheet rather than looking for them in the window.
#
# Every fixture here is built by driving the app. The previous suite had to seed the retired row with an
# `INSERT` (`Archive/Tests/Bench/08b-categories-tab-checklist.md` Scenario C, Step 3) because its window
# did not re-read the list when a row was retired, so a category retired through the checkbox left the
# screen and the database disagreeing. This app reloads the pane on the write, so create-then-retire is
# both the path a user takes and the one that leaves the window honest.

# Creates a category and retires it, leaving exactly one retired row under `name` and no active one.
# Prints its id.
make_retired() {
    local name="$1" id
    press create-category
    sleep 0.5
    set_field category-name-field "$name"
    press save-category
    wait_for_value "SELECT COUNT(*) FROM category WHERE category_name = '$name' AND active = 1;" "1" 10 || return 1
    id=$(sql "SELECT category_id FROM category WHERE category_name = '$name' AND active = 1;")
    press "category-active-$id"
    wait_for_value "SELECT active FROM category WHERE category_id = $id;" "0" 10 || return 1
    printf '%s' "$id"
}

# Types `name` into the create control and saves it, which is what raises the alert.
ask_about() {
    press create-category
    sleep 0.5
    set_field category-name-field "$1"
    press save-category
    sleep 1.2
}

# How many rows hold the name, and how many of those are active. One query so a check reads
# "1 row, 0 active" rather than two figures that were true at different moments.
tally() {
    sql "SELECT COUNT(*) || ' rows, ' || SUM(active) || ' active' FROM category WHERE category_name = '$1';"
}

# ---------------------------------------------------------------------------- one namesake, three ways
#
# A separate name per path, because each answer changes the fixture: reactivating consumes the retired
# row, and creating a new one leaves two rows where the next path needs one.

REACTIVATE="$NAME reactivate"
CREATE_NEW="$NAME create new"
CANCELLED="$NAME cancelled"

# ---- the alert itself

reactivate_id=$(make_retired "$REACTIVATE")
if [ -z "$reactivate_id" ]; then
    fail "could not make a retired category, so the namesake checks below have no fixture"
    finish
    exit 1
fi
check "one deactivated category holds the name ($REACTIVATE)" "1 rows, 0 active" "$(tally "$REACTIVATE")"

since=$(mark)
ask_about "$REACTIVATE"
expect_log "typing it again asks instead of inserting" "$since" "%Save new category \"$REACTIVATE\" -> asking, 1 retired%"
check "and nothing is created while the question is open" "1 rows, 0 active" "$(tally "$REACTIVATE")"

# The order is the order they are drawn, and on this platform the first is the default and sits
# rightmost. Reactivate leads because it is the answer that keeps the history.
check "the alert offers three buttons" "Reactivate|Create new one|Cancel" "$(alert_buttons)"

# ---- Reactivate

since=$(mark)
press_title Reactivate
sleep 1
expect_log "Reactivate brings that one back" "$since" "%Reactivate \"$REACTIVATE\" -> category_id $reactivate_id%"
check "the same row is active again" "1" "$(sql "SELECT active FROM category WHERE category_id = $reactivate_id;")"

# **The whole point of this answer.** A new row under the same name would leave every time entry filed
# against the old one behind, which is what the other button is for.
check "and it is still one row, not a second one" "1 rows, 1 active" "$(tally "$REACTIVATE")"
check_contains "its row is back on the active table" "$(tree)" "id=category-name-$reactivate_id"

# ---- Create new one

create_new_id=$(make_retired "$CREATE_NEW")
check "a second name with one deactivated category ($CREATE_NEW)" "1 rows, 0 active" "$(tally "$CREATE_NEW")"

since=$(mark)
ask_about "$CREATE_NEW"
press_title "Create new one"
sleep 1
expect_log "Create new one inserts alongside it" "$since" "%Create new one \"$CREATE_NEW\" -> category_id%leaving category_id $create_new_id retired%"

# Two rows sharing a name, one active. Legal because `UN1_category` bars duplicates only among active
# categories, and it is the shape the second half of this section needs.
check "there are now two rows, one active" "2 rows, 1 active" "$(tally "$CREATE_NEW")"
check "the old one was left retired" "0" "$(sql "SELECT active FROM category WHERE category_id = $create_new_id;")"

# ---- Cancel

cancelled_id=$(make_retired "$CANCELLED")
check "a third name with one deactivated category ($CANCELLED)" "1 rows, 0 active" "$(tally "$CANCELLED")"

since=$(mark)
ask_about "$CANCELLED"
press_title Cancel
sleep 1
expect_log "Cancel creates nothing" "$since" "%Cancel, \"$CANCELLED\" not created%"
check "the name is still held by one retired row" "1 rows, 0 active" "$(tally "$CANCELLED")"

# A modal sheet nobody dismissed makes every press below land on nothing, and the failures then arrive
# somewhere that has no bearing on the cause.
check "and the alert is gone" "no" "$(alert_is_open && echo yes || echo no)"

# ---------------------------------------------------------------------------- several namesakes, two ways
#
# Retiring the row Create new one just made leaves two retired categories sharing the name, which is the
# case where no button can say which one to bring back.

active_create_new=$(sql "SELECT category_id FROM category WHERE category_name = '$CREATE_NEW' AND active = 1;")
press "category-active-$active_create_new"
sleep 1
check "retiring the newer one leaves two deactivated under the name" "2 rows, 0 active" "$(tally "$CREATE_NEW")"

since=$(mark)
ask_about "$CREATE_NEW"
expect_log "the alert says how many there are" "$since" "%Save new category \"$CREATE_NEW\" -> asking, 2 retired%"

# **The absent button is the assertion.** Offering Reactivate here would mean the app picking one of two
# identically named rows on the user's behalf, which is the thing it cannot know. Creating is still
# offered, since only an *active* namesake bars a name.
check "the alert offers two buttons, and no Reactivate" "Create new one|Cancel" "$(alert_buttons)"

# ---- Cancel, first, so the create path can be last

since=$(mark)
press_title Cancel
sleep 1
expect_log "Cancel still creates nothing" "$since" "%Cancel, \"$CREATE_NEW\" not created%"
check "both retired rows are untouched" "2 rows, 0 active" "$(tally "$CREATE_NEW")"

# ---- Create new one

since=$(mark)
ask_about "$CREATE_NEW"
press_title "Create new one"
sleep 1
expect_log "Create new one still inserts" "$since" "%Create new one \"$CREATE_NEW\" -> category_id%"
check "a third row under the name, and only it is active" "3 rows, 1 active" "$(tally "$CREATE_NEW")"
check "the two retired ones are still retired" "2" "$(sql "SELECT COUNT(*) FROM category WHERE category_name = '$CREATE_NEW' AND active = 0;")"
check "and the alert is gone" "no" "$(alert_is_open && echo yes || echo no)"

# ---------------------------------------------------------------------------- the dead end
#
# The third collision, and the only one with nothing to decide: an **active** category holds the name, so
# there is no second answer to offer. One button, and it only dismisses.

since=$(mark)
ask_about "$RENAMED"
expect_log "a name an active category holds is refused outright" "$since" "%Save new category \"$RENAMED\" -> already active as category_id $ID%"
check "the alert offers one button, which only dismisses" "Ok" "$(alert_buttons)"
press_title Ok
sleep 0.8
check "nothing was created" "1" "$(sql "SELECT COUNT(*) FROM category WHERE category_name = '$RENAMED';")"

# ---------------------------------------------------------------------------- reinstating is refused
#
# Ticking a retired row's Active box when an active category already holds the name. `$CREATE_NEW` is
# exactly that shape by now: two retired and one active, all under one name.
#
# **The question is asked before the write, for the message.** The unique index over active names would
# refuse it anyway and has the last word, but a refusal from the index cannot say *which* category is in
# the way, and that is the whole of what somebody needs to hear.

blocked=$(sql "SELECT category_id FROM category WHERE category_name = '$CREATE_NEW' AND active = 0 ORDER BY category_id LIMIT 1;")
holder=$(sql "SELECT category_id FROM category WHERE category_name = '$CREATE_NEW' AND active = 1;")

if ! tree | grep -q "retired-category-name-$blocked"; then
    press categories-inactive-section-heading-button
    sleep 1
fi

since=$(mark)
press "retired-category-active-$blocked"
sleep 1
expect_log "reinstating onto an active name is refused, naming what is in the way" "$since" \
    "%\"$CREATE_NEW\" reinstate REFUSED: category_id $holder is active under that name%"
check "the row is still retired" "0" "$(sql "SELECT active FROM category WHERE category_id = $blocked;")"
check_contains "and the alert says which name" "$(python3 scripts/ax-alert.py --message 2>/dev/null)" "already in use"
press_title OK
sleep 0.5

# **The box goes back to unticked.** It claimed something the table never agreed to, and a control still
# showing the click is the two-answers problem in miniature.
check_contains "the row is still in the Inactive list" "$(tree)" "id=retired-category-name-$blocked"

# ---------------------------------------------------------------------------- a retired row is a record
#
# **No icon, no colour, no daily limit.** A retired category is a record of what it was, not a setting
# worth tuning. The Active box stays live, because reinstating is the one edit it must still allow.

check "a retired row draws no icon button" "0" "$(tree | grep -c "id=category-icon-$blocked" || true)"
check "no colour button" "0" "$(tree | grep -c "id=category-colour-$blocked" || true)"
check "and no daily limit field" "0" "$(tree | grep -c "id=category-limit-$blocked" || true)"
check_contains "but its Active box is there" "$(tree)" "id=retired-category-active-$blocked"

# ---------------------------------------------------------------------------- colour and icon
#
# Both are popovers anchored to the row, and both write to the table. `0` is the seeded *None* row rather
# than a null, which is how either is cleared while the foreign key still holds.

since=$(mark)
press "category-colour-$ID"
sleep 0.8
check_contains "the colour list opens" "$(tree)" "id=colour-option-Red"
press colour-option-Red
sleep 1
check "picking Red writes Red, by id" "$(sql "SELECT colour_id FROM colour WHERE colour_name = 'Red';")" \
    "$(sql "SELECT colour_id FROM category WHERE category_id = $ID;")"

first_icon=$(sql "SELECT icon_name FROM icon WHERE icon_id = 1;")
since=$(mark)
press "category-icon-$ID"
sleep 0.8
check_contains "the icon grid opens" "$(tree)" "id=icon-cell-$first_icon"
press "icon-cell-$first_icon"
sleep 1
check "picking an icon writes it" "1" "$(sql "SELECT icon_id FROM category WHERE category_id = $ID;")"

# Picking the one already chosen clears it, which is the only way back to None.
press "category-icon-$ID"
sleep 0.8
press "icon-cell-$first_icon"
sleep 1
check "picking it again clears it to None" "0" "$(sql "SELECT icon_id FROM category WHERE category_id = $ID;")"

# ---------------------------------------------------------------------------- the daily limit
#
# In minutes, with 0 meaning no limit. It commits like every other stepped field: typed, then Return.

others_before=$(sql "SELECT IFNULL(SUM(daily_limit), 0) FROM category WHERE category_id != $ID;")

# The field carries the identifier itself (`SteppedNumberField` puts it on the text field, with `-up` and
# `-down` on the arrows), so it is typed into directly.
#
# **Focused first, not just written to.** Setting AXValue changes what the field shows without opening an
# editing session, so the Return that follows has nothing to commit and goes wherever focus actually is.
# That failed silently on 2026-08-16: the tree read `category-limit-3 value=45` while the table still held
# 0, and the check that caught it was the one reading the table.
set_field_focused "category-limit-$ID" "45"
press_return
sleep 1
check "a typed daily limit is written" "45" "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"

# **Nobody else moved.** A field that wrote to the wrong row would still pass the check above.
check "and no other category's limit moved" "$others_before" \
    "$(sql "SELECT IFNULL(SUM(daily_limit), 0) FROM category WHERE category_id != $ID;")"

# ---------------------------------------------------------------------------- holding an arrow
#
# A click is one step; holding keeps stepping, by 1 at first and then by 5, and **slower once it is
# stepping by 5**. Those are the numbers in `StepperHoldRules`: 0.1s per single step, 0.3s per five, after
# a 0.4s wait before the repeat starts at all.
#
# **The slowing down is the part worth testing.** A control that changed step size without changing pace
# would move five times faster the moment it crossed the boundary and run away from whoever is holding it.
# Nothing about that is visible in the value it lands on, so only the timing catches it.
#
# It is readable because every tick writes its own row: `report` calls `onChange` for each value the hold
# passes through, and `debug_log.logged_at` keeps milliseconds. `press` cannot do this -- a stepper arrow
# leaves the action path to `performClick`, which is the single-step path -- so `ax-hold.py` posts a real
# mouse down, waits, and posts the up.

# ---- up, from zero

set_field_focused "category-limit-$ID" "0"
press_return
sleep 1
check "the limit is back to zero, to hold up from" "0" "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"

since=$(mark)
announce "holding the up arrow steps 1 to 10, then by fives"
python3 scripts/ax-hold.py "category-limit-$ID-up" 3.0 >/dev/null 2>&1
sleep 1.5
up=$(python3 Tests/Scripted/stepper-timing.py "$since" "$RENAMED" 2>/dev/null)
up_values=$(printf '%s' "$up" | sed -n 's/^values=//p')
case "$up_values" in
    1,2,3,4,5,6,7,8,9,10,15,20*) verdict_pass; grey "          $up_values" ;;
    *) verdict_fail "the sequence was '$up_values'" ;;
esac

up_singles=$(printf '%s' "$up" | sed -n 's/.*singles_avg_ms=//p')
up_fives=$(printf '%s' "$up" | sed -n 's/.*fives_avg_ms=//p')
announce "and the fives are slower than the ones (${up_singles}ms then ${up_fives}ms)"
# Two rather than the three the intervals are in, because a tick's row is written when the app got round
# to it: the ratio is real but the ends of it are noisy.
if [ "${up_fives:-0}" -gt $(( ${up_singles:-1} * 2 )) ]; then
    verdict_pass
else
    verdict_fail "${up_fives}ms is not meaningfully slower than ${up_singles}ms"
fi

# ---- down, from forty
#
# The boundary is measured from where the hold began, in the direction of travel, so holding down from 40
# counts 35 and then 30: ticks by 1 down to 30, then by 5.

set_field_focused "category-limit-$ID" "40"
press_return
sleep 1
check "the limit is at forty, to hold down from" "40" "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"

# Held long enough to reach 0 and then half a second longer, which is the part worth holding for. From 40
# that is ten single steps to 30, then 25, 20, 15, 10, 5, 0 at the slower interval: about 3.2 seconds. The
# hold stops itself at the bottom -- `holdStep` returns nil once a tick clamps back to where it already
# was -- so the extra time is spent proving nothing further happens rather than waiting for it to finish.
since=$(mark)
announce "holding the down arrow steps 39 to 30, then by fives"
python3 scripts/ax-hold.py "category-limit-$ID-down" 4.5 >/dev/null 2>&1
sleep 1.5
down=$(python3 Tests/Scripted/stepper-timing.py "$since" "$RENAMED" 2>/dev/null)
down_values=$(printf '%s' "$down" | sed -n 's/^values=//p')
case "$down_values" in
    39,38,37,36,35,34,33,32,31,30,25,20*) verdict_pass; grey "          $down_values" ;;
    *) verdict_fail "the sequence was '$down_values'" ;;
esac

down_singles=$(printf '%s' "$down" | sed -n 's/.*singles_avg_ms=//p')
down_fives=$(printf '%s' "$down" | sed -n 's/.*fives_avg_ms=//p')
announce "and going down slows down too (${down_singles}ms then ${down_fives}ms)"
if [ "${down_fives:-0}" -gt $(( ${down_singles:-1} * 2 )) ]; then
    verdict_pass
else
    verdict_fail "${down_fives}ms is not meaningfully slower than ${down_singles}ms"
fi

# ---- the floor
#
# **Held past the bottom on purpose.** The arrow was still down for half a second after the value reached
# 0, so this is not "it happened to stop in time": it is that a hold with nowhere left to go stops instead
# of ticking into negative numbers. `holdStep` returns nil when a tick clamps back to the value it already
# had, which is what ends it.

check "holding down runs out at zero" "0" "$(sql "SELECT daily_limit FROM category WHERE category_id = $ID;")"

announce "and the last thing it stepped to was zero, having held past it"
case "$down_values" in
    *,0) verdict_pass ;;
    *) verdict_fail "the sequence ended '$(printf '%s' "$down_values" | sed 's/.*\(,[^,]*,[^,]*\)$/\1/')' rather than at 0" ;;
esac

# A negative would be a minus sign in the list, and there is no other reason for one to be there.
announce "with nothing below zero anywhere in it"
case "$down_values" in
    *-*) verdict_fail "the sequence went negative: $down_values" ;;
    *) verdict_pass ;;
esac

# ---------------------------------------------------------------------------- the rename dead ends
#
# The rename itself is checked at the top. What is checked here is the two answers that are not "yes", and
# the one collision that only looks like a collision.

# ---- Cancel leaves the name alone

since=$(mark)
begin_rename "$ID"
set_field_focused "category-name-$ID-field" "$NAME abandoned"
press_return
sleep 1
press_title Cancel
sleep 1
expect_log "cancelling a rename is recorded" "$since" "%not renamed%"
check "and the name is untouched" "$RENAMED" "$(sql "SELECT category_name FROM category WHERE category_id = $ID;")"

# ---- a rejected name is handed back, not thrown away
#
# **The field stays open, still holding what was typed.** Renaming onto a name an active category already
# holds is refused, and the refusal leaves the edit exactly where it was so it can be corrected or
# abandoned. Closing it would make the only two things left to do -- fix the name, or give up -- both start
# with retyping it.
#
# This is the one rename outcome that does not reload the row, and deliberately so: every other one is
# finished, and this one is not.

since=$(mark)
begin_rename "$reactivate_id"
set_field_focused "category-name-$reactivate_id-field" "$RENAMED"
press_return
sleep 1
check "renaming onto an active name offers only Cancel" "Cancel" "$(alert_buttons)"
press_title Cancel
sleep 1

check "the table is untouched" "$REACTIVATE" "$(sql "SELECT category_name FROM category WHERE category_id = $reactivate_id;")"

# The field, not the button. A row showing its old name again would mean the typed one was discarded.
check_contains "the field is still open after the refusal" "$(element "category-name-$reactivate_id-field")" \
    "id=category-name-$reactivate_id-field"
check_contains "still holding the name that was rejected, ready to be fixed" \
    "$(element "category-name-$reactivate_id-field")" "value=$RENAMED"

# ---- fixing it in place, without starting again
#
# Straight into the open field, with no press to reopen it, because that is the whole point of leaving it
# open. The correction doubles as the case that only looks like a collision: **a row is not in its own
# way.** Names are matched case-insensitively, as the unique index is, so a category matches itself when
# only its capitalisation changes, and refusing that would make the one edit nobody can argue with
# impossible.

CAPITALISED=$(printf '%s' "$REACTIVATE" | tr '[:lower:]' '[:upper:]')
since=$(mark)
set_field_focused "category-name-$reactivate_id-field" "$CAPITALISED"
press_return
sleep 1
expect_log "correcting it in the open field is offered, not refused" "$since" "%rename -> \"$CAPITALISED\", asking%"
press_title Rename
sleep 1
check "and the correction lands" "$CAPITALISED" "$(sql "SELECT category_name FROM category WHERE category_id = $reactivate_id;")"

# Finished this time, so the row goes back to being a name rather than a field.
check_contains "the field closes once a rename is accepted" "$(tree)" "id=category-name-$reactivate_id "

finish
