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


# The vertical distance between the two stacked chevrons' centers: `arrowHeight` +
# `arrowSpacing` from `SettingsLayoutConstants.Stepper`. Keep in step with that enum.
_AUTOPAUSE_ARROW_PITCH = 11.0


def _autopause_up_arrow_rect():
    """The auto-pause stepper's two `image` elements both report the *upper* chevron's frame -- a
    SwiftUI quirk collapsing the pair's custom-drawn glyphs onto one frame -- so `image 2` is no
    use and the lower arrow has to be derived from this rect plus the stack's pitch.

    Anchoring on the arrow itself rather than on a hand-measured offset from the neighbouring text
    field is deliberate: the arrows used to sit *ahead* of the field and moved to *after* it (and
    after the `min` suffix) when the row was restyled to match every other stepper in the window,
    which silently sent the old offset into empty space."""
    script = (
        'tell application "System Events" to tell process "TimeFlip" '
        'to get {position, size} of image 1 of group 2 of scroll area 1 of group 1 '
        'of window "TimeFlip Settings"'
    )
    out = _osascript(script)
    x, y, w, h = (float(p.strip()) for p in out.split(","))
    return x, y, w, h


def autopause_up_arrow_point():
    x, y, w, h = _autopause_up_arrow_rect()
    return x + w / 2, y + h / 2


def autopause_down_arrow_point():
    x, y, w, h = _autopause_up_arrow_rect()
    return x + w / 2, y + h / 2 + _AUTOPAUSE_ARROW_PITCH


LOCATORS = {
    "status_item_right": status_item_right_point,
    "status_item_left": status_item_left_point,
    "autopause_up_arrow": autopause_up_arrow_point,
    "autopause_down_arrow": autopause_down_arrow_point,
}
