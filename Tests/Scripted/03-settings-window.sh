#!/bin/bash
# The Settings window: its five tabs, moving between them, and closing it.
#
# **The tabs carry no `AXIdentifier`.** A Settings tab button has to be matched on its description
# instead, which is Archive/Tests/Methods.md Method 10's finding from the previous app and is still true
# of this one. `select_tab` is that, in one place, so no script rediscovers it as a regression.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_test_database
ensure_app_running
start "the Settings window and its tabs"

open_settings
check "the window is open" "yes" "$(settings_is_open && echo yes || echo no)"

# **Off Faces first.** The tab view's delegate does not fire for a tab that is already selected, and the
# window always opens on Faces, so a loop starting there would wait for a row that is never written --
# which is not the app failing but the script asking for the wrong evidence. `SettingsWindowController`
# says as much where it logs the open.
select_tab Device

# Every tab, in the order they sit in the window. Each one is selected and then checked twice: the app
# said it selected it, and the pane it names is actually in the tree. The first alone would pass on a
# tab that logged the change and drew nothing.
for tab in Faces Categories Report App Device; do
    since=$(mark)
    select_tab "$tab"
    expect_log "the $tab tab can be selected" "$since" "Settings tab selected: $tab"

    pane=$(python3 scripts/ax-dump.py 2>/dev/null | grep -c "id=settings-pane-$(echo "$tab" | tr '[:upper:]' '[:lower:]')" || true)
    if [ "${pane:-0}" -gt 0 ]; then
        pass "the $tab pane is on screen"
    else
        fail "the $tab tab was selected but its pane is not in the tree"
    fi
done

# ---------------------------------------------------------------------------- coming back

# Closing and reopening re-reads everything rather than showing what the last open loaded, which is the
# first rule in CLAUDE.md applied to this window. What is checked here is the cheaper half of it: that
# the window goes away and comes back at all.
since=$(mark)
close_settings
expect_log "the Close button is recorded" "$since" "Button clicked: Close (Settings window)"
check "the window is gone" "no" "$(settings_is_open && echo yes || echo no)"

open_settings
check "it opens again" "yes" "$(settings_is_open && echo yes || echo no)"

# **It always opens on Faces**, whatever was showing when it was closed, which is deliberate: what is
# being timed is what somebody opening this window most often wants, and a window that reopened on the
# Device tab because that is where they last were would bury it. The row is written by the open itself
# rather than by the tab view, precisely because selecting an already-selected tab fires nothing.
opened=$(sql "SELECT message FROM debug_log WHERE message LIKE 'Settings opened on %' ORDER BY debug_log_id DESC LIMIT 1;")
check_contains "it opens on Faces however it was left" "$opened" "Faces"

finish
