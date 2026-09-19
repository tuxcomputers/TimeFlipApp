#!/usr/bin/env python3
"""Post a real keystroke, with modifiers, to whatever holds the X focus.

    scripts/at-key.py return               # commit an inline edit
    scripts/at-key.py v --command          # paste
    scripts/at-key.py a --command          # select all
    scripts/at-key.py escape

The Linux counterpart of `ax-key.py`, and it exists for the same reason: a shortcut is not an action.
`at-press.py` presses a control by name and `at-set.py` writes a field outright, and neither goes
anywhere near the path a keyboard shortcut takes. So a shortcut is only provable by sending it.

**`--command` is Control here, which is the platform's own equivalent and not a rename.** The flag
keeps the macOS spelling so that a check reads the same on both platforms, which is the whole point
of going through `platform.sh`; what the modifier *is* differs because the platforms differ.

**It goes wherever the X focus is**, so the window has to be focused first or the key lands in the
terminal the check is being run from -- which is a real way to lose a Return into a shell. `--focus`
does that, and is the default.

Exits non-zero, with the reason, on anything that stops the key going out -- the app not running, a
key nobody can name -- rather than posting nothing and saying it worked.
"""

import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])

import gi                                                               # noqa: E402

gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")

import pyatspi                                                          # noqa: E402
from gi.repository import Gdk, GdkX11                                   # noqa: E402

from atspi_tree import application, find, role_of                       # noqa: E402

# The keys a check actually names, spelled the way `ax-key.py` spells them so the two families take
# the same words. Anything else is looked up by `Gdk.keyval_from_name`, which knows the X names.
KEYSYMS = {
    "return": 0xFF0D,
    "enter": 0xFF0D,
    "escape": 0xFF1B,
    "tab": 0xFF09,
    "space": 0x0020,
    "delete": 0xFFFF,
    "backspace": 0xFF08,
}

CONTROL_L = 0xFFE3


def keysym_for(name):
    lowered = name.lower()
    if lowered in KEYSYMS:
        return KEYSYMS[lowered]
    if len(name) == 1:
        return ord(name)
    value = Gdk.keyval_from_name(name)
    if value == 0:
        sys.exit(f"no key is called {name!r}. Try a single character, or an X key name like Escape.")
    return value


def focus_the_app(root):
    """Put the X focus on the app's window, so the key lands in it rather than in a terminal."""
    frame = find(root, lambda node: role_of(node) == "frame", whole_tree=True)
    if frame is None:
        sys.exit("the app has no window on screen, so there is nothing to send a key to")
    try:
        component = frame.queryComponent()
        component.grabFocus()
    except Exception as error:                                          # noqa: BLE001
        sys.exit(f"could not focus the app window: {error}")
    return frame


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("key", help="a character, or a name like return or escape")
    parser.add_argument("--app", default="FacetLinux", help="the application to send to")
    parser.add_argument("--command", action="store_true", help="hold Control (macOS Command)")
    parser.add_argument("--no-focus", action="store_true", help="send it wherever focus already is")
    arguments = parser.parse_args()

    root = application(arguments.app)
    if not arguments.no_focus:
        focus_the_app(root)

    keysym = keysym_for(arguments.key)

    # **Pressed and released around it rather than sent as one event.** XTEST has no notion of a
    # modified keystroke; the modifier is a key that is down while another is struck, exactly as on a
    # real keyboard, and leaving it down would modify whatever the user typed next.
    if arguments.command:
        pyatspi.Registry.generateKeyboardEvent(CONTROL_L, None, pyatspi.KEY_PRESS)
    try:
        pyatspi.Registry.generateKeyboardEvent(keysym, None, pyatspi.KEY_SYM)
    finally:
        if arguments.command:
            pyatspi.Registry.generateKeyboardEvent(CONTROL_L, None, pyatspi.KEY_RELEASE)

    held = "Control+" if arguments.command else ""
    print(f"sent {held}{arguments.key}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
