#!/usr/bin/env python3
"""Post a real keystroke, with modifiers, to whatever holds focus.

    scripts/ax-key.py v --command          # paste
    scripts/ax-key.py a --command          # select all
    scripts/ax-key.py return               # commit an inline edit

**Because a shortcut is not an action.** Accessibility can press a control by name (`ax-press.py`) and can
write a field's value outright (`ax-set.py`), and neither of those goes anywhere near the path a keyboard
shortcut takes: `NSApplication.sendEvent` offers a key-down to `mainMenu.performKeyEquivalent` first, and
only the item found there turns the keystroke into `paste(_:)` on the field editor. So ⌘V is only provable
by posting ⌘V -- `MainMenu`'s unit tests can say the item exists and carry the right key, and that is the
whole of what they can say.

This posts a real key event on the real keyboard. It goes wherever focus is, so the app is activated first
and the caller has to have put focus in the right place already (opening an inline edit does that; see
`Tests/Methods.md` Method 10). Nothing here belongs in a run somebody is using the machine during.

Exits non-zero, with the reason, on anything that stops the key going out -- the app not running, a key
nobody can name -- rather than posting nothing and saying it worked.
"""

import subprocess
import sys
import time

import Quartz
from AppKit import NSWorkspace

# The virtual key codes for what a script actually needs. Named rather than numeric at the call site,
# because `36` in a test script is a number nobody can check without a table.
KEYS = {
    "a": 0, "c": 8, "v": 9, "x": 7, "z": 6,
    "return": 36, "tab": 48, "space": 49, "delete": 51,
}

MODIFIERS = {
    "--command": Quartz.kCGEventFlagMaskCommand,
    "--shift": Quartz.kCGEventFlagMaskShift,
    "--option": Quartz.kCGEventFlagMaskAlternate,
    "--control": Quartz.kCGEventFlagMaskControl,
}


def main():
    if len(sys.argv) < 2:
        sys.exit(f"usage: ax-key.py <{'|'.join(KEYS)}> [{' '.join(MODIFIERS)}] [--app Facet]")

    key = sys.argv[1].lower()
    if key not in KEYS:
        sys.exit(f"no key code for {key!r}; known keys are {', '.join(sorted(KEYS))}")

    arguments = sys.argv[2:]
    app_name = "Facet"
    if "--app" in arguments:
        index = arguments.index("--app")
        if index + 1 >= len(arguments):
            sys.exit("--app needs a name after it")
        app_name = arguments[index + 1]
        del arguments[index:index + 2]

    flags = 0
    for argument in arguments:
        if argument not in MODIFIERS:
            sys.exit(f"unknown option {argument!r}; modifiers are {', '.join(sorted(MODIFIERS))}")
        flags |= MODIFIERS[argument]

    running = any(
        a.localizedName() == app_name for a in NSWorkspace.sharedWorkspace().runningApplications()
    )
    if not running:
        sys.exit(f"{app_name} is not running")

    # The key goes to whatever is focused, so the app has to be in front first -- otherwise it lands in
    # whatever the caller is being driven from, which is the one failure that looks like the app ignoring it.
    subprocess.run(["osascript", "-e", f'tell application "{app_name}" to activate'], check=False)
    time.sleep(0.4)

    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, KEYS[key], down)
        # Set on both halves. A flag on the down alone leaves the up looking like a different chord, and
        # AppKit has been seen to hold the modifier down afterwards.
        Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)

    named = "+".join([argument.lstrip("-") for argument in arguments] + [key])
    print(f"posted {named} to {app_name}")


if __name__ == "__main__":
    main()
