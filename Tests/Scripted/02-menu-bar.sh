#!/bin/bash
# The status item: what it says, what its menu holds, and that the two halves do different things.
#
# **The status item is not in the app's window tree and not in `AXMenuBar` until its menu is open**, so
# it is reached by clicking a screen point rather than by name (`scripts/status-item-click.py`, and
# Tests/Methods.md on why). That is the one piece of driving here that is not "press by name".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
# What this script checks when everything passes. See `finish` in lib.sh for what a mismatch means.
EXPECTED_CHECKS=9
start "the menu bar item, its title and its menu"

close_settings

# ---------------------------------------------------------------------------- what it says

# The title is drawn from the database every time rather than pushed at it, so it is also the quickest
# read on whether the app is following what is recorded.
title=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true)
if [ -n "$title" ]; then
    pass "the status item is in the menu bar"
    grey "          $title"
else
    fail "no status item found in the menu bar"
fi

# **Nothing in the title names the database any more.** The `TEST`/`PROD`/`DB?` tag was removed on
# 2026-09-04 with the developer flag it was drawn for: which database a run writes to is `setting.db_type`
# and `require_test_database`'s job, which every script in this folder already goes through before it
# starts, rather than a permanent tag in the one line the app has to say what it is doing.

# ---------------------------------------------------------------------------- the left half

since=$(mark)
click_left || fail "the status item would not click, so nothing below could be checked"
sleep 0.8
expect_log "a left click opens the menu" "$since" "%side=left%showMenu%"

menu=$(python3 scripts/ax-dump.py --menu-bar 2>/dev/null)
check_contains "the menu offers Settings" "$menu" "id=open-settings"
check_contains "the menu offers Quit" "$menu" "id=quit-app"
# One item, not two: the same control says Pause or Resume depending on what is happening, because
# there is one question being asked and a menu with both would be asking it twice.
check_contains "the menu offers the pause control" "$menu" "id=toggle-pause"
paused=$(printf '%s' "$menu" | grep -c "id=toggle-pause" || true)
check "there is exactly one pause item" "1" "$paused"

# ---------------------------------------------------------------------------- into the window

since=$(mark)
press open-settings
sleep 1.5
expect_log "choosing Settings is recorded" "$since" "Menu item clicked: Settings"
check "the Settings window opened" "yes" "$(settings_is_open && echo yes || echo no)"

# It opens where it was left rather than always on the first tab, which the log names as it happens.
expect_log "the window says which tab it opened on" "$since" "Settings opened on %"

finish
