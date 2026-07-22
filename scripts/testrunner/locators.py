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


def _autopause_text_field_rect():
    script = (
        'tell application "System Events" to tell process "TimeFlip" '
        'to get {position, size} of text field 1 of group 2 of scroll area 1 of group 1 '
        'of window "TimeFlip Settings"'
    )
    out = _osascript(script)
    x, y, w, h = (float(p.strip()) for p in out.split(","))
    return x, y, w, h


def autopause_up_arrow_point():
    """The stepper's two `image` elements report identical, unusable AX geometry (a SwiftUI
    quirk collapsing custom-drawn glyphs to their container's frame) -- this offset from the
    adjacent, reliable text field was derived empirically via a screencapture crop."""
    x, y, w, h = _autopause_text_field_rect()
    return x - 16, y + 3


def autopause_down_arrow_point():
    x, y, w, h = _autopause_text_field_rect()
    return x - 16, y + 14


LOCATORS = {
    "status_item_right": status_item_right_point,
    "status_item_left": status_item_left_point,
    "autopause_up_arrow": autopause_up_arrow_point,
    "autopause_down_arrow": autopause_down_arrow_point,
}
