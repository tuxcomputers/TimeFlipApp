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

# **Removed 2026-09-20, having been called from nowhere for some time.** `platform_not_yet` existed for
# the functions below that had no Linux half yet, and there are none left: item 11 built the app and the
# window-driving section further down is the rest of it. What is genuinely absent on this platform is now
# refused *at the place it is absent*, saying why rather than pointing at a list -- `platform_click_right`
# is the one, and its refusal explains that an AppIndicator has no right half rather than implying
# somebody forgot to write one.

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
#
# **The replacement is a bare `~` and must stay one.** Bash does no tilde expansion in the replacement half
# of `${var/pat/rep}`, so nothing needs escaping there, and a `\~` is not an escaped tilde but a backslash
# followed by one. That row is JSON, where `\~` is an invalid escape, so the setting stops parsing and the
# debug trace every check polls is never written.
SUPPORT_TILDE="${SUPPORT/#$HOME/~}"

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
            # **One call where the Mac needs two**, and that is the whole of the difference between the
            # platforms here. A status item's menu items do not exist in the accessibility tree until a
            # real mouse event has opened it, so that side has to click and then press; the tray menu on
            # this side is a D-Bus object whose items can be read and chosen without opening it at all.
            # `Tests/Methods.md` Method 18.
            #
            # Said out loud when it fails, never swallowed: a Quit that did not happen makes the wait
            # after it time out and report whatever it was waiting on, which is what
            # `>/dev/null 2>&1` on the macOS press cost this suite twice (see `CLAUDE.md`).
            local output status
            output=$(python3 scripts/tray-menu.py --press Quit 2>&1)
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "  the tray Quit would not press (exit $status)${output:+: $output}"
                echo "  falling back to a kill"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------- driving the window

# **The window half of the port, added 2026-09-20.** Everything above this was already here; what was
# missing was that `lib.sh` reached the macOS accessibility scripts by name, so every check in the suite
# was macOS-only however platform-aware this file had become. The Linux counterparts are
# `scripts/at-*.py`, which take the same arguments for the same jobs.
#
# **The two families do not mean the same thing by the same attribute**, which is the reason these
# wrappers exist rather than a variable holding a prefix. On macOS `AXIdentifier`, `AXTitle` and
# `AXValue` are three attributes; on Linux a `GtkButton` reports its label as its accessible *name*, so
# a control that wants an identifier has to overwrite it and its value goes in the description. A check
# written against `--desc` would therefore be asking for the label on one platform and the value on the
# other -- so no check names either family, and these decide.

# Press a control by identifier.
platform_press() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-press.py "$1" 2>&1 ;;
        linux) python3 scripts/at-press.py "$1" 2>&1 ;;
    esac
}

# Press a control by the words on it, which is how every dialogue button is addressed.
platform_press_title() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-press.py --title "$1" 2>&1 ;;
        # **No flag needed on this side**, and that is a fact about the platform rather than a shortcut:
        # `facet_dialog_add_button` gives the button its title, and an unidentified `GtkButton` reports
        # its label as its accessible name. So the words *are* the name here.
        linux) python3 scripts/at-press.py "$1" 2>&1 ;;
    esac
}

# Press by the description, for controls that carry their label there.
platform_press_desc() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-press.py --desc "$1" 2>&1 ;;
        linux) python3 scripts/at-press.py --desc "$1" 2>&1 ;;
    esac
}

# A button of the dialogue that is up, addressed as part of the dialogue rather than of the window.
platform_press_sheet() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-press.py --sheet --title "$1" 2>&1 ;;
        # **A dialogue is a top-level of its own here, not a sheet on the window**, so there is nothing
        # to scope to and the ordinary press finds it. `GtkDialoguePresenter` runs `gtk_dialog_run`,
        # which spins a nested main loop, and the tree is readable and drivable throughout.
        linux) python3 scripts/at-press.py "$1" 2>&1 ;;
    esac
}

# Move to a Settings tab.
#
# **Two genuinely different gestures, which is why this is a step of its own.** A macOS segmented
# control's segments carry their label as a description and are pressed; a GTK `page tab` implements no
# Action interface at all and is *selected*, through the Selection interface of the tab list above it.
# `Tests/Methods.md` Method 20.
platform_select_tab() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-press.py --desc "$1" 2>&1 ;;
        linux) python3 scripts/at-press.py --tab "$1" 2>&1 ;;
    esac
}

# Write into a field.
platform_set_field() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-set.py "$1" "$2" 2>&1 ;;
        linux) python3 scripts/at-set.py "$1" "$2" 2>&1 ;;
    esac
}

# The same, having put focus in the field first.
platform_set_field_focused() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-set.py --focus "$1" "$2" 2>&1 ;;
        # `at-set.py` writes through the accessible interface, which does not need or move focus, so
        # there is no second form of it. Named the same so a check reads the same.
        linux) python3 scripts/at-set.py "$1" "$2" 2>&1 ;;
    esac
}

# A real keystroke, to whatever holds focus.
platform_key() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-key.py "$@" 2>&1 ;;
        linux) python3 scripts/at-key.py "$@" 2>&1 ;;
    esac
}

# Press and hold, for the stepper repeat that an accessible action cannot reach.
platform_hold() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-hold.py "$1" "$2" 2>&1 ;;
        linux) python3 scripts/at-hold.py "$1" "$2" 2>&1 ;;
    esac
}

# The whole tree, for the checks that grep it.
platform_tree() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-dump.py 2>/dev/null ;;
        linux) python3 scripts/at-dump.py 2>/dev/null ;;
    esac
}

# The tree with each element's position and size.
platform_tree_frames() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-dump.py --frames 2>/dev/null ;;
        linux) python3 scripts/at-dump.py --frames 2>/dev/null ;;
    esac
}

# The buttons of the dialogue that is up, one per line. Non-zero when there is no dialogue.
platform_alert_buttons() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-alert.py 2>/dev/null ;;
        linux) python3 scripts/at-alert.py 2>/dev/null ;;
    esac
}

# Its wording instead.
platform_alert_message() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-alert.py --message 2>/dev/null ;;
        linux) python3 scripts/at-alert.py --message 2>/dev/null ;;
    esac
}

# ---------------------------------------------------------------------------- the status item

# What the status item is showing, as a line a check can grep.
#
# **Neither platform has it in the accessibility tree**, and they answer that in opposite ways: macOS
# puts the item in the menu bar's own tree, which `ax-dump.py --menu-bar` reads, and the tray here is a
# D-Bus object with the words as properties on it. `Tests/Methods.md` Method 18.
platform_status_item() {
    case "$PLATFORM" in
        mac)   python3 scripts/ax-dump.py --menu-bar 2>/dev/null | grep -m1 "id=status-item" || true ;;
        linux) python3 scripts/tray-menu.py --label 2>/dev/null || true ;;
    esac
}

# Open the status item's menu, so that its items can be addressed.
#
# **A no-op on Linux, and that is the honest answer rather than a gap.** The menu is a
# `com.canonical.dbusmenu` object whose items can be read and chosen without it ever being opened, so
# there is nothing to open: `platform_menu_press` below works whether or not this was called.
platform_open_menu() {
    case "$PLATFORM" in
        mac)   python3 scripts/status-item-click.py 2>&1 ;;
        linux) return 0 ;;
    esac
}

# Choose an item of the status item's menu, **named by its identifier on both platforms**.
#
# `menu_press open-settings` reads the same in every check, and this decides how to reach it. On macOS
# the identifier is what `AXIdentifier` carries and the press is by name. On Linux nothing carries it:
# `com.canonical.dbusmenu` answers with the label and `enabled`, and the numeric ids it does give out
# are libdbusmenu's own and are reassigned whenever the menu is rebuilt (measured 2026-09-13, see
# `scripts/tray-menu.py`). So this side maps the identifier to the title.
#
# **Both sides of that mapping come from `StatusItemMenu`**, which is core and shared, so the titles
# are not invented here -- `Item("Settings…", identifier: Identifier.settings)` is the line, and the
# same build puts both halves on screen.
#
# **Two of the items change their wording with their state**, which is the whole of why this is a case
# and not a lookup table. Pause reads *Resume* while paused and Lock reads *Unlock* while locked, and
# they are still the same item doing the same job -- so both titles are offered and whichever the menu
# is currently showing is the one that gets pressed.
platform_menu_press() {
    case "$PLATFORM" in
        mac) python3 scripts/ax-press.py "$1" 2>&1 ;;
        linux)
            local titles output
            case "$1" in
                open-settings)    titles="Settings…" ;;
                quit-app)         titles="Quit" ;;
                toggle-pause)     titles="Pause|Resume" ;;
                toggle-cube-lock) titles="Lock|Unlock" ;;
                *)
                    echo "  no tray item is known by the identifier $1." >&2
                    echo "  the mapping is in platform_menu_press, beside StatusItemMenu.Identifier." >&2
                    return 1 ;;
            esac
            local IFS='|'
            for title in $titles; do
                unset IFS
                output=$(python3 scripts/tray-menu.py --press "$title" 2>&1) && {
                    printf '%s\n' "$output"
                    return 0
                }
            done
            unset IFS
            echo "  no tray item matching $1 (tried ${titles//|/ or })${output:+: $output}" >&2
            return 1 ;;
    esac
}

# **The right half of the status item, which is a macOS gesture and has no counterpart here.**
#
# It is not merely unimplemented: an `AppIndicator` publishes one activation and the panel decides what
# a secondary click does, so there is no right half for the app to distinguish and nothing it could
# listen for. The pause-on-right-click gesture that `12-daily-limit` and `62-forced-pause` turn on does
# not exist on this platform, and the app does not pretend it does.
#
# So this refuses loudly rather than returning success, because a gesture that silently did nothing
# would make the wait after it time out and blame the cube -- which is the exact failure `CLAUDE.md`
# records twice.
platform_click_right() {
    case "$PLATFORM" in
        mac)   python3 scripts/status-item-click.py --right "$@" 2>&1 ;;
        linux)
            echo "  the status item has no right half on Linux: an AppIndicator publishes one" >&2
            echo "  activation and the panel owns the secondary click, so there is no gesture to" >&2
            echo "  post. The checks that need it are item 12 of docs/linux-port.md." >&2
            return 1 ;;
    esac
}

# ---------------------------------------------------------------------------- the radio

# **Is the Bluetooth radio on? 0 yes, 1 no, 2 cannot tell.**
#
# Three answers rather than two, for the reason `platform_app_is_declared` has three: not being able to ask
# says nothing about the answer, and this is the one probe in the suite whose wrong answer *asks the person
# to do something they have already done*. `lib.sh`'s comment records that happening once from a different
# cause on 2026-08-22.
#
# **It was `system_profiler SPBluetoothDataType` for both platforms until 2026-09-20**, which does not exist
# on Linux -- so the command printed nothing, the `case` fell through to its catch-all, and the suite told
# the owner to turn on a radio that was already on, then failed `00-setup` and stopped the run. A macOS tool
# reached directly from a shared file, which is the same fault as `lib.sh` reaching `ax-press.py`, and it
# survived that sweep because it is a system probe rather than a way of driving the window.
platform_bluetooth_is_on() {
    case "$PLATFORM" in
        mac)
            # Captured and matched rather than piped into `grep -q`, for the reason `tree_has` sets out:
            # this is sourced into files that set pipefail, `system_profiler` writes a great deal after the
            # line that matches, and a pipeline killed by SIGPIPE reports the signal rather than the match.
            #
            # The literal is what the tool prints, `          State: On`, one space after the colon.
            local report
            report="$(system_profiler SPBluetoothDataType 2>/dev/null)"
            [ -z "$report" ] && return 2
            case "$report" in
                *"State: On"*) return 0 ;;
                *) return 1 ;;
            esac ;;
        linux)
            # **Asked of BlueZ, which is what the app itself talks to.** `BlueZRadio` reaches the same
            # adapter over D-Bus, so the adapter's `Powered` property is the same fact the app will act on
            # -- where `rfkill` answers a different question, whether the device is *blocked*, and an
            # unblocked adapter can still be powered down.
            #
            # **Timed out**, because `bluetoothctl` waits on a D-Bus reply and a stuck bluetoothd would
            # otherwise hang the whole run at its first setup step with nothing said.
            command -v bluetoothctl >/dev/null 2>&1 || return 2
            local report
            report="$(timeout 5 bluetoothctl show 2>/dev/null)"
            [ -z "$report" ] && return 2
            case "$report" in
                *"Powered: yes"*) return 0 ;;
                *"Powered: no"*) return 1 ;;
                # No controller at all: `bluetoothctl show` prints `No default controller available`. That
                # is not the radio being off, it is there being no radio, and the two want different words
                # in front of somebody -- so it is the third answer rather than the second.
                *) return 2 ;;
            esac ;;
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

# **A unix epoch formatted as a date, which the two systems spell incompatibly rather than merely
# differently.** `date -r` exists on both and means opposite things: BSD reads it as *this epoch*, GNU as
# *this file\'s modification time*. So the macOS spelling on Linux goes looking for a file named
# `1789900000`, fails with `No such file or directory`, and prints **nothing** -- and a comparison against
# an empty string is false, which is a wrong answer rather than an error.
#
# That is what failed `00-setup` on the first real Linux run (2026-09-20): `the seeds are dated
# 2026-09-20, not today`, on the twentieth. Same shape as `platform_binary_built_at` above, whose comment
# records `stat` doing the same thing in the other direction.
platform_date_from_epoch() {
    case "$PLATFORM" in
        mac)   date -r "$1" "+$2" ;;
        linux) date -d "@$1" "+$2" ;;
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
# deliberately not on `PATH` on the Linux box, where it lives under `~/.local/swift`.
#
# **This used to print the `export` line and give up**, which was honest and was still the wrong shape: a
# script that knows the path well enough to print it knows it well enough to use it, and every run of the
# suite on this box began with the same two-line ceremony. Changed 2026-09-20, after `run.sh` refused for
# exactly that reason.
#
# **It says what it did rather than doing it quietly**, which is the half that matters: a toolchain nobody
# chose is the sort of thing that should be visible in a log when a build behaves oddly.
#
# **An already-set `PATH` wins**, because putting swift there is a deliberate act and this must not
# second-guess it. And **more than one toolchain is a refusal rather than a guess** -- picking the
# alphabetically-last of two would be choosing somebody's compiler for them, and the resulting failure
# would be attributed to the code.
platform_swift_is_available() {
    command -v swift >/dev/null 2>&1 && return 0

    local found=()
    local candidate
    for candidate in "$HOME"/.local/swift/*/usr/bin/swift; do
        [ -x "$candidate" ] && found+=("$candidate")
    done

    case "${#found[@]}" in
        0)
            echo "  swift is not on PATH, and there is no toolchain under ~/.local/swift." >&2
            echo "  install one, or put it on PATH yourself:" >&2
            echo "  export PATH=\"\$HOME/.local/swift/<version>/usr/bin:\$PATH\"" >&2
            return 1 ;;
        1)
            local bin
            bin="$(dirname "${found[0]}")"
            export PATH="$bin:$PATH"
            echo "  swift was not on PATH; using the toolchain at $bin"
            return 0 ;;
        *)
            echo "  swift is not on PATH and there is more than one toolchain under ~/.local/swift," >&2
            echo "  so this will not choose one for you:" >&2
            for candidate in "${found[@]}"; do
                echo "    $(dirname "$candidate")" >&2
            done
            echo "  put the one you want on PATH and run this again." >&2
            return 1 ;;
    esac
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
