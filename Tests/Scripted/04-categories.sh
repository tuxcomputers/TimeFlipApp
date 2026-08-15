#!/bin/bash
# The Categories tab: creating one, renaming it, retiring it, and bringing it back.
#
# Everything below this script depends on a category existing, since a face holds one and a time entry is
# filed under one. It runs before them for that reason.
#
# **The category it makes is named after the clock and left behind.** Two runs must not collide -- an
# active name is unique, so a fixed name would fail the second time -- and nothing here deletes what it
# made, because the rows are the evidence. Expect a row of `Scripted HH:MM:SS` categories to build up on
# the test database; that is the intended cost of runs you can go back and read.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "creating, renaming, retiring and reinstating a category"

open_settings
select_tab Categories

NAME="Scripted $(date '+%H:%M:%S')"
RENAMED="$NAME renamed"

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
press "category-name-$ID"
sleep 0.5
set_field "category-name-$ID-field" "$RENAMED"
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

finish
