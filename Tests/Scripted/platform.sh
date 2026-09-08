#!/bin/bash
# Which machine this is, and every operation that differs between them. Sourced, never run.
#
# **One variable, `PLATFORM`, and everything that varies hangs off it.** The scripted suite drives a real
# app through a real window, and that is the half of it no two operating systems share: the same *step* --
# quit the app, press a control, read the tray -- reaches it by a different *method* on each. What must not
# vary is the step, because a check that is written twice is two checks that can drift apart, and the whole
# claim of this suite is that it says what the app does rather than what one platform's version of it does.
#
# So a script says `platform_quit_app`, and this file decides what that means. Nothing above this line ever
# asks which machine it is on.
#
# **The values, not only the functions.** Where the app keeps its database, what the binary is called and
# what the run's stamp is named are platform facts too, and having them here rather than spelled out in
# three files is what stops one of them being updated and the others not.
#
# Sourced by `run.sh`, `lib.sh` and `testlog.sh`, in any order and more than once, so it is idempotent.

# Sourced more than once in a run -- `run.sh` takes it and so does `lib.sh` -- so it does its work once.
# **Guarded on a name of its own rather than on `PLATFORM`**, because guarding on the answer would let an
# exported `PLATFORM=mac` walk in from the environment and quietly redirect every path in the suite at a
# directory that does not exist. What this file decides, it decides from `uname`.
[ -n "${_PLATFORM_SH_SOURCED:-}" ] && return 0
_PLATFORM_SH_SOURCED=1

# **`PLATFORM_OVERRIDE` is for exercising the other platform's values, and nothing else.** It cannot make
# the other platform's *methods* work -- `ax-press.py` is not going to run here -- so it is good for
# checking that the paths and names come out right and is a lie in every other respect. Nothing in the
# suite sets it.
case "${PLATFORM_OVERRIDE:-$(uname -s)}" in
    mac|Darwin) PLATFORM=mac ;;
    linux|Linux) PLATFORM=linux ;;
    *)
        # **Loudly, and not as a default.** Guessing that an unknown system is close enough to one of these
        # would drive a real app with the wrong method and report whatever came of it as a test result.
        echo "This suite knows how to drive macOS and Linux. ${PLATFORM_OVERRIDE:-$(uname -s)} is neither," >&2
        echo "so it will not guess." >&2
        return 1
        ;;
esac

# **What is not built yet says so, at the moment it is reached.** The Linux app is item 11 of
# `docs/linux-port.md` and the suite that drives it is item 12; until both exist, several of the functions
# below have nothing to call. They fail through here rather than returning quietly, because a step that
# does nothing and reports success is exactly the fault `CLAUDE.md` forbids -- and it would be reported
# later, somewhere else, as the app misbehaving.
platform_not_yet() {
    echo "  not yet on Linux: $1" >&2
    echo "  (docs/linux-port.md item ${2:-11})" >&2
    return 1
}

# ---------------------------------------------------------------------------- where things are

case "$PLATFORM" in
    mac)
        # `~/Library/Application Support/Facet`, which is what `.applicationSupportDirectory` answers there.
        SUPPORT="$HOME/Library/Application Support/Facet"
        APP=".build/bundler/apps/Facet/Facet.app"
        BINARY="$APP/Contents/MacOS/Facet"
        PROCESS_NAME="Facet"
        STAMP="Tests/Scripted/last-run-mac.md"
        ;;
    linux)
        # **`~/.local/share/Facet`, and this is measured rather than assumed** (2026-09-08, on the Linux
        # box): a real binary linked against `FacetCore` was asked what
        # `FileManager.urls(for: .applicationSupportDirectory)` answers, and it said `/home/<user>/.local/share`.
        # Corelibs applies the XDG layout on its own, so no code in the app had to change for it.
        SUPPORT="$HOME/.local/share/Facet"
        # **Deliberately empty.** What the Linux app is called and where it is built are decided by item 11,
        # and inventing a plausible path here would be a fact this file made up. Anything that needs them
        # goes through the functions below, which say so.
        APP=""
        BINARY=""
        PROCESS_NAME=""
        STAMP="Tests/Scripted/last-run-linux.md"
        ;;
esac

DB="$SUPPORT/appdata.sqlite"
# The trace, in its own file beside the app's. See `lib.sh` for why the two are separate.
DEBUG_DB="$SUPPORT/debug.sqlite"

# ---------------------------------------------------------------------------- driving the app

# Is it up?
platform_app_is_running() {
    case "$PLATFORM" in
        mac)   pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 ;;
        linux) [ -n "$PROCESS_NAME" ] && pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 ;;
    esac
}

# The last resort, when a tidy quit did not work.
platform_kill_app() {
    case "$PLATFORM" in
        mac)   pkill -x "$PROCESS_NAME" ;;
        linux) [ -n "$PROCESS_NAME" ] && pkill -x "$PROCESS_NAME" ;;
    esac
}

# **Quit it the way a person would**, through the menu the app puts in front of them, so that the quit
# sequence actually runs. A killed app never gets to do what it does on the way out, and that is a thing
# these checks care about.
#
# Both halves are said out loud when they fail. `run.sh` used to throw the output of each away, and a click
# that never happened cost a run twenty seconds and a wrong diagnosis (see `CLAUDE.md`).
platform_quit_app() {
    case "$PLATFORM" in
        mac)
            python3 scripts/status-item-click.py 2>&1 \
                || echo "  the status item would not click; falling back to a kill"
            sleep 0.5
            python3 scripts/ax-press.py quit-app 2>&1 \
                || echo "  quit-app would not press; falling back to a kill"
            ;;
        linux)
            platform_not_yet "quitting the app -- there is no Linux app to quit" 11
            ;;
    esac
}

# ---------------------------------------------------------------------------- facts about the run

# When the binary under test was built. `stat` takes opposite flags on the two systems, and the BSD one
# silently produces nothing on Linux rather than failing, which would have written an empty column.
platform_binary_built_at() {
    [ -n "$BINARY" ] || return 0
    case "$PLATFORM" in
        mac)   stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$BINARY" 2>/dev/null || echo "" ;;
        linux) stat -c '%y' "$BINARY" 2>/dev/null | cut -d'.' -f1 || echo "" ;;
    esac
}

# The operating system version, for the run record.
platform_os_version() {
    case "$PLATFORM" in
        mac)   sw_vers -productVersion 2>/dev/null || echo "" ;;
        linux) . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || echo "" ;;
    esac
}

# **Whether the binary is properly signed, which is a macOS question and only a macOS question.** Ad-hoc
# signing silently breaks anything reading the Keychain, and that once made a build flag look like a Google
# outage. Linux has no equivalent to get wrong, so it answers what is true rather than borrowing a word.
#
# **Captured and matched, never piped into `grep -q`.** This is reached from files that set `pipefail`, and
# a pipeline whose reader exits early reports the writer's SIGPIPE rather than the match -- which made every
# run from 89 to 94 record `ad-hoc` against an app signed with a real Apple Development certificate. See
# `tree_has` in `lib.sh` for the measurement.
platform_signing() {
    case "$PLATFORM" in
        mac)
            case "$(codesign -dvvv "$APP" 2>&1)" in
                *TeamIdentifier=[A-Z0-9]*) echo "signed" ;;
                *) echo "ad-hoc" ;;
            esac
            ;;
        linux) echo "not applicable" ;;
    esac
}
