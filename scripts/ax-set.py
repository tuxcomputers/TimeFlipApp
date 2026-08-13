#!/usr/bin/env python3
"""Put text into a field of a running app, found by name anywhere in its accessibility tree.

    scripts/ax-set.py category-name-field "Admin"

Sets the element's AXValue, which is how to fill a field without synthetic keystrokes. Keystrokes go
wherever focus happens to be, and that is not necessarily the app being driven -- a named element
cannot be missed the same way.

An NSTextField's action fires on Return and on losing focus, not on this write, so something still has
to commit it: press the Save button beside it (scripts/ax-press.py), or move focus.

Exits non-zero when nothing matches. Needs accessibility permission for whatever runs it.
"""
import subprocess, sys
from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    AXUIElementSetAttributeValue, kAXErrorSuccess,
)

def attribute(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == kAXErrorSuccess else None

def walk(element, wanted, depth=0):
    if depth > 25:
        return None
    if attribute(element, "AXIdentifier") == wanted:
        return element
    for child in (attribute(element, "AXChildren") or []):
        found = walk(child, wanted, depth + 1)
        if found is not None:
            return found
    return None

identifier, value = sys.argv[1], sys.argv[2]
pid = int(subprocess.check_output(["pgrep", "-x", "TimeFlip"]).split()[0])
app = AXUIElementCreateApplication(pid)
target = None
for window in (attribute(app, "AXWindows") or []):
    target = walk(window, identifier)
    if target is not None:
        break
if target is None:
    print("not found", file=sys.stderr); sys.exit(1)
err = AXUIElementSetAttributeValue(target, "AXValue", value)
print(f"set {identifier} = {value!r}: {'ok' if err == kAXErrorSuccess else f'error {err}'}")
