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
        # **There is no bundle**, so there is no `.app` and the binary is the whole of it. `swift build`
        # puts an executable product straight into the bin directory, and `.build/debug` is a symlink to
        # the triple's copy of it -- which matters for more than tidiness: `Facet_FacetCore.resources`
        # lands in that same directory, and a binary run from anywhere else dies on a `fatalError` the
        # first time it wants the DDL. Measured 2026-09-08; see linux-port.md.
        APP=""
        # **Derived from the product rather than invented.** `FacetMac` is what `Package.swift` already
        # calls the executable product on the other platform, so it is what a Linux one would be called
        # too -- and nothing here trusts that: `platform_app_is_declared` asks SwiftPM whether the product
        # exists at all, and `platform_build_app` checks the binary actually appeared where this says.
        LINUX_PRODUCT="FacetLinux"
        BINARY=".build/debug/$LINUX_PRODUCT"
        PROCESS_NAME="$LINUX_PRODUCT"
        STAMP="Tests/Scripted/last-run-linux.md"
        ;;
esac

# **The same directory written the way a person writes it**, for the one place it is stored rather than
# used: `00-setup` puts the debug trace's directory into a `setting` row, and the app expands the tilde on
# its way back out. Kept beside the absolute form so the two cannot name different places.
SUPPORT_TILDE="${SUPPORT/#$HOME/\~}"

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

# **How many copies of it are up.** `01-launch` asks because a second launch must hand over to the first
# rather than join it, and "one" is the answer that says so.
platform_app_instances() {
    [ -n "$PROCESS_NAME" ] || { echo 0; return 0; }
    pgrep -x "$PROCESS_NAME" | wc -l | tr -d ' '
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

# ---------------------------------------------------------------------------- building and launching

# **Is there an app to build at all?** Asked of SwiftPM rather than worked out from the manifest's text,
# because the manifest builds a different graph per platform and only SwiftPM knows what it decided. It
# answers in about a quarter of a second and builds nothing.
#
# On Linux today it answers no: `Package.swift` gives this platform `allProducts: [Product] = []`, which is
# item 11. The moment that item adds the product this starts answering yes on its own, with nothing here to
# remember to change.
#
# **0 yes, 1 no, 2 cannot tell**, and the third is not folded into the second for the reason
# `InstanceLock.Denial.cannotTell` exists in the app: not being able to ask says nothing about the answer,
# and reporting "there is no app" when the truth is "swift is not on PATH" sends somebody to the wrong file.
platform_app_is_declared() {
    case "$PLATFORM" in
        mac) [ -f Bundler.toml ] ;;
        linux)
            platform_swift_is_available || return 2
            # **The products list, read as JSON rather than grepped.** A grep for the name matches the
            # *package*, which is also called `FacetMac`, so it answered yes on a platform with no products
            # at all. Nothing else in the file would have caught it: the wrong answer was the encouraging one.
            swift package describe --type json 2>/dev/null | python3 -c '
import json, sys
try:
    described = json.load(sys.stdin)
except Exception:
    sys.exit(2)
sys.exit(0 if any(p.get("name") == sys.argv[1] for p in described.get("products", [])) else 1)
' "$LINUX_PRODUCT" ;;
    esac
}

# **Swift has to be found before it can be asked anything.** It is on `PATH` from Xcode on the Mac and is
# deliberately not on `PATH` on the Linux box, so this says the line that puts it there rather than leaving
# a `command not found` to be interpreted.
platform_swift_is_available() {
    command -v swift >/dev/null 2>&1 && return 0
    echo "  swift is not on PATH." >&2
    echo "  export PATH=\"\$HOME/.local/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:\$PATH\"" >&2
    return 1
}

# **Builds the app, and says everything it did wrong.** The caller decides what a failure means; this
# reports one honestly and returns non-zero. Fifteen lines of output on failure, because a build error is
# usually one line and reproducing it by hand was the cost of throwing it away.
platform_build_app() {
    # **Before the build on both platforms.** `10-google-calendar` signs in, so the binary being tested has
    # to carry the Google client the same way a real one does. Its failure is worth hearing: a build that
    # quietly lost its credentials fails later, in a Google script, looking like a broken account.
    local credentials_output credentials_status
    credentials_output=$(scripts/generate-credentials.sh 2>&1)
    credentials_status=$?
    if [ "$credentials_status" -ne 0 ]; then
        echo "  the Google credentials step failed (exit $credentials_status)${credentials_output:+: $credentials_output}" >&2
        return 1
    fi

    local output status
    case "$PLATFORM" in
        mac)
            # **Signed, exactly as scripts/run.sh signs it.** An ad-hoc build is a different application to
            # the Keychain, so the refresh token behind Google sync stops being readable without a prompt --
            # and nothing says so: the sweep just never runs. That is how 10-google-calendar failed the first
            # time it was written, against a binary this function had built unsigned.
            #
            # **Quoted, and passed as its own argument.** An identity reads
            # `Apple Development: apple@tux.com.au (32Q68X4KAP)` -- three words -- so building the flags into
            # one string and letting it word-split hands swift-bundler three arguments it has never heard of.
            # It went unnoticed because it only bites when a rebuild actually happens, which is the run after
            # a source file changes and no other. `scripts/run.sh` had it right; this had not.
            local identity
            identity="$(scripts/codesign-identity.sh)"
            if [ -n "$identity" ]; then
                output=$(mint run stackotter/swift-bundler@main bundle Facet --codesign --identity "$identity" 2>&1)
                status=$?
            else
                echo "  no codesigning identity, so this build is ad-hoc: anything reading the Keychain will stall"
                output=$(mint run stackotter/swift-bundler@main bundle Facet 2>&1)
                status=$?
            fi
            ;;
        linux)
            # **No bundler and no signing**: there is no `.app` to make and nothing to sign, so the build is
            # the plain SwiftPM one. `--product` rather than a bare `swift build` so that a missing product
            # is an error naming what is missing, rather than a build that succeeds having made no app.
            platform_swift_is_available || return 1
            output=$(swift build --product "$LINUX_PRODUCT" 2>&1)
            status=$?
            ;;
    esac

    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" | tail -15 | sed 's/^/    /' >&2
        return 1
    fi

    # **The build reporting success is not the binary existing.** Checked rather than assumed, for the same
    # reason a command sent to the cube is read back: a build that produced nothing at this path would
    # otherwise be found out by the launch, which reports it as the app failing to start.
    if [ ! -x "$BINARY" ]; then
        echo "  the build succeeded but there is no executable at $BINARY" >&2
        return 1
    fi
    return 0
}

# **Starts it detached**, so the suite keeps its own terminal and the app outlives the shell that began it.
platform_launch_app() {
    case "$PLATFORM" in
        mac) open "$APP" ;;
        linux)
            # Its console copy goes to a file rather than to the run log: every line it prints is also a
            # `debug_log` row, which is what the checks read, but a crash on the way up prints there and
            # nowhere else.
            mkdir -p logs
            nohup "$BINARY" >> logs/app.log 2>&1 &
            ;;
    esac
}

# **A warning that only one platform can earn.** Ad-hoc signing makes every build a different application
# to the Keychain, so Google sync stalls on a prompt and nothing says why. Linux has no equivalent, so it
# has nothing to warn about rather than a warning worded to look similar.
platform_warn_if_unsigned() {
    case "$PLATFORM" in
        mac)
            # Captured and matched rather than piped into `grep -q`: see `tree_has` in lib.sh for why a
            # pipeline cannot answer this under pipefail. It said ad-hoc about a properly signed app on 18
            # runs out of 20, which is the wrong way round for a warning nobody can act on.
            case "$(codesign -dvvv "$APP" 2>&1)" in
                *TeamIdentifier=[A-Z0-9]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        linux) return 1 ;;
    esac
}
