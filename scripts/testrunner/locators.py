"""Named on-screen targets for cgevent_click, resolved live via accessibility.

Each function returns an (x, y) point in screen points (not pixels) suitable for
CGEventCreateMouseEvent. Position/size are re-read every call since these controls'
geometry (especially the status item's width) shifts with content.
"""

import subprocess


def _osascript(script):
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"osascript failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _status_item_rect():
    script = (
        'tell application "System Events" to tell process "TimeFlip" '
        'to get {position, size} of menu bar item 1 of menu bar 2'
    )
    out = _osascript(script)
    x, y, w, h = (float(p.strip()) for p in out.split(","))
    return x, y, w, h


def status_item_right_point():
    x, y, w, h = _status_item_rect()
    return x + w * 0.75, y + h / 2


def status_item_left_point():
    x, y, w, h = _status_item_rect()
    return x + w * 0.25, y + h / 2


LOCATORS = {
    "status_item_right": status_item_right_point,
    "status_item_left": status_item_left_point,
}
