#!/usr/bin/env python3
"""Press and hold a button of a running app, found by name anywhere in its accessibility tree.

    scripts/ax-hold.py category-limit-1-up 2.0      # hold the up arrow for two seconds

Accessibility has no hold: AXPress is always a click. So this reads the element's own position and
posts real mouse events there -- button down, wait, button up -- which is the only way to drive
anything that repeats while held, such as a stepper's accelerating arrows.

Real events land wherever the pointer is put, so the app has to be on screen and nobody should be
touching the mouse while it runs.

Read the result from debug_log rather than from the final value when the timing is what is being
checked, since the rows carry the cadence as well as the sequence.

Exits non-zero when nothing matches. Needs accessibility permission for whatever runs it.
"""
import subprocess, sys, time
import Quartz
from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    AXValueGetValue, kAXErrorSuccess, kAXValueCGPointType, kAXValueCGSizeType,
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

identifier, seconds = sys.argv[1], float(sys.argv[2])
pid = int(subprocess.check_output(["pgrep", "-x", "Facet"]).split()[0])
app = AXUIElementCreateApplication(pid)
target = None
for window in (attribute(app, "AXWindows") or []):
    target = walk(window, identifier)
    if target is not None:
        break
if target is None:
    print("not found", file=sys.stderr); sys.exit(1)

ok, position = AXValueGetValue(attribute(target, "AXPosition"), kAXValueCGPointType, None)
ok2, size = AXValueGetValue(attribute(target, "AXSize"), kAXValueCGSizeType, None)
x, y = position.x + size.width / 2, position.y + size.height / 2

def post(kind):
    event = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventSetIntegerValueField(event, Quartz.kCGMouseEventClickState, 1)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

print(f"holding {identifier} at ({x:.0f}, {y:.0f}) for {seconds}s")
post(Quartz.kCGEventLeftMouseDown)
time.sleep(seconds)
post(Quartz.kCGEventLeftMouseUp)
print("released")
