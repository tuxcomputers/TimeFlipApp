"""Action-type registry: each function executes one checklist step's TOML spec.

Every action returns a StepResult(success, detail, captured). `ctx` is a shared dict
carrying `db_path` and `vars` (a name -> value store steps can write to via `capture`
and read from via `$name` placeholders in query/command/script/expect strings).

`$name` (string.Template), not Python str.format's `{name}`, is deliberate: query text
routinely contains literal JSON like `{"enabled":false}`, which `.format()` misparses as
a field placeholder and crashes on. `$name` doesn't collide with `{`/`}` at all.
"""

import json
import re
import subprocess
import sqlite3
import time
from dataclasses import dataclass
from string import Template
from typing import Any, Optional

from locators import LOCATORS


_CONDITION_RE = re.compile(r"\s*(<=|>=|==|!=|<|>)\s*")


def condition_met(cond, ctx):
    """Evaluate a `when` guard against captured vars, e.g. "$start_event_id < 10". One
    comparison (< <= > >= == !=); numeric if both sides parse as numbers, else a string
    compare. A blank/unparseable guard counts as met so the step runs (fail open, never
    silently skip). Usable both on a whole step (see supervisor.run_checklist) and on an
    individual action inside an `[[actions]]` block (see run_step)."""
    text = Template(cond).safe_substitute(ctx["vars"]).strip()
    m = _CONDITION_RE.search(text)
    if not m:
        return True
    op = m.group(1)
    lhs, rhs = text[: m.start()].strip(), text[m.end():].strip()
    try:
        left, right = float(lhs), float(rhs)
    except ValueError:
        left, right = lhs, rhs
    return {
        "<": lambda: left < right,
        "<=": lambda: left <= right,
        ">": lambda: left > right,
        ">=": lambda: left >= right,
        "==": lambda: left == right,
        "!=": lambda: left != right,
    }[op]()


@dataclass
class StepResult:
    success: bool
    detail: str
    captured: Optional[Any] = None
    # The one thing this action *read* (a db value, a matched log line, a y/n answer), already
    # formatted. None for an action that merely *does* something (a click, a shell command, a
    # keystroke). The console never prints this -- a pass is always a bare "-> PASS" -- it goes
    # to the `step_value` table instead (run_record.py), which keeps it across runs. `detail`
    # stays the full diagnostic text, used on a failure.
    value: Optional[str] = None
    # On a failure with an assertion behind it, the two halves the reader actually wants, printed
    # as separate "Expected:"/"Result:" lines. Both None for a failure with nothing to compare
    # (a shell command's non-zero exit, an exception) -- then `detail` is printed instead.
    expected: Optional[str] = None
    actual: Optional[str] = None


# Width of the hashed box naming the checklist a run has reached (see print_checklist_banner).
# The starred action box is not this wide: it is sized to its own title, see print_action_banner.
CHECKLIST_BANNER_WIDTH = 70

# Spaces between the starred action box's title and its two side walls.
ACTION_BANNER_PADDING = 2

# How long act_wait_for_sql polls quietly before alerting the developer that it's still waiting. A
# relaunched app needs a few seconds to find the device and log `Login accepted`, so an instant
# alert would fire on every restart and clear itself moments later. (Deliberately NOT applied to
# ask_user/ask_user_or_detect: those wait on a person doing something, so nothing will happen at
# all until they're told -- those still ask straight away.)
ALERT_AFTER_SECONDS = 5


def print_action_banner(title="Action required"):
    """The starred box announcing that the run needs a person. A run scrolls a long way on its own,
    so the point where it is waiting has to be findable at a glance rather than reading as one more
    result line. Printed on its own so a caller can put the step's own text inside the box's shadow,
    above the nudge (see supervisor's human-verified step).

    Sized to its title rather than to a fixed width, so it hugs the words:

        *********************
        *  Action required  *
        *********************

    That makes it a compact flag beside the step it interrupts, distinct from the full-width
    checklist box below, which is a divider between whole checklists and is meant to be a wall."""
    inner = len(title) + ACTION_BANNER_PADDING * 2
    bar = "*" * (inner + 2)
    print(bar)
    print(f"*{title.center(inner)}*")
    print(bar)


def print_checklist_banner(name):
    """The hashed box naming the checklist the steps below belong to.

    Full width, unlike the action box, because it divides one checklist from the next rather than
    flagging a moment inside one. Together with `print_scenario_header` this is what lets a step
    line be a bare "Step 3: ..." -- the checklist and the scenario are the headings above it
    instead of a prefix repeated on every line. The log file has read this way for a while
    (`run_checklist` writes the section as a sub-heading); the console now matches it."""
    bar = "#" * CHECKLIST_BANNER_WIDTH
    print(bar)
    print(f"#{name.center(CHECKLIST_BANNER_WIDTH - 2)}#")
    print(bar)


def print_scenario_header(section):
    """The scenario sub-heading under a checklist banner:

        ####### Scenario B -- quit and relaunch resumes from ... #######

    The `## ` heading uncut (`Step.section_full`), not the short "Scenario B" that keys the run
    record, because the part after the dash is the only place a run says what a scenario is *for*.

    Narrower and lighter than the boxes on purpose. A run raises one of these every few steps, so a
    full box would flatten the difference between "the next few steps are a new scenario" and the
    two things that genuinely interrupt a reader: a new checklist, and the run needing a person."""
    print(f"####### {section} #######")


def print_action_required(message, title="Action required", header=None):
    """The banner, the step it is about, then the nudge itself -- always in that order.

    `header` is the step's console line. Passing it puts the step *inside* the box's shadow rather
    than above it, which is what makes a nudge readable when a wait has been polling quietly for a
    while and the step that asked for it has scrolled off. Every path that asks a person for
    something goes through here, so the three lines always arrive in the same order (see
    `step_asks_immediately` for the one case where the supervisor prints the first two itself)."""
    print_action_banner(title)
    if header:
        print(header)
    print(f">>> ACTION NEEDED: {message}")


def print_action_nudge(message):
    """Just the nudge, for when the banner and the step header are already on screen directly
    above it (the supervisor prints them before running a step that asks straight away)."""
    print(f">>> ACTION NEEDED: {message}")


def step_asks_immediately(spec):
    """Whether this step puts a question to a person the moment it runs, rather than only if a
    wait goes unsatisfied. True for `ask_user`/`ask_user_or_detect` anywhere in the step; a
    `wait_for_sql` `prompt` is deferred by design (it nudges only after the grace period, so
    announcing it up front would cry wolf on every step that is already satisfied)."""
    if not spec:
        return False
    subs = spec["actions"] if "actions" in spec else [spec]
    return any(sub.get("action") in ("ask_user", "ask_user_or_detect") for sub in subs)


def _announce(prompt, ctx):
    """Put the nudge on screen under a banner and the step it belongs to.

    The supervisor prints those two itself for a step it knows will ask straight away, so that the
    banner comes *before* the step rather than under it. This consumes that flag: a second ask
    later in the same step (a deferred wait after an answered question) announces itself again
    rather than arriving bare, long after the first box has scrolled away."""
    if ctx.get("banner_shown"):
        ctx["banner_shown"] = False
        print_action_nudge(prompt)
        return
    print_action_required(prompt, header=ctx.get("step_header"))


def _pretty_value(text):
    """Console form of a value read from the DB. A single-key JSON object shows just its value
    (`{"type":"production"}` -> `production`) -- the step text already says which setting is
    being read, so the key is noise. Anything else is passed through unchanged."""
    t = str(text).strip()
    if t.startswith("{") and t.endswith("}"):
        try:
            obj = json.loads(t)
        except ValueError:
            return t
        if isinstance(obj, dict) and len(obj) == 1:
            v = next(iter(obj.values()))
            return v if isinstance(v, str) else json.dumps(v)
    return t


def _sub(text, ctx):
    return Template(text).safe_substitute(ctx["vars"])


def _remember_capture(spec, ctx, value):
    """Mirror a just-captured value into the `captured_value` table, keyed by run, checklist and
    scenario, so a later resume can recover it (see remembered.py). `test`/`section` are put on
    ctx by the supervisor per step. No-op when no recorder is attached (e.g. unit tests) or the
    step captures nothing."""
    rec = ctx.get("remembered")
    if rec is not None and spec.get("capture"):
        rec.record(ctx.get("test", "?"), ctx.get("section", "?"), spec["capture"], value)


_REMEMBERED_VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")


def resolve_missing_vars_from_remembered(spec, ctx):
    """Before a step runs, fill any `$var` it references that isn't already in ctx['vars'] from
    the remembered file -- a value a *previous* scenario captured, needed when a resume skipped
    that scenario so it never ran this session. Already-set vars are left untouched; a var that
    nothing ever recorded stays unresolved, exactly as before. No-op without a recorder/spec."""
    rec = ctx.get("remembered")
    if rec is None or not spec:
        return
    test = ctx.get("test", "")
    for m in _REMEMBERED_VAR_RE.finditer(json.dumps(spec)):
        name = m.group(1) or m.group(2)
        if name in ctx["vars"]:
            continue
        val = rec.lookup(test, name)
        if val is not None:
            ctx["vars"][name] = val


def _run_sql(db_path, query):
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute(query)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description] if cur.description else []
        return rows, cols
    finally:
        conn.close()


def _format_rows(rows, cols):
    if not rows:
        return "(no rows)"
    if len(rows) == 1 and len(rows[0]) == 1:
        return str(rows[0][0])
    return "; ".join(", ".join(f"{c}={v}" for c, v in zip(cols, row)) for row in rows)


def act_shell(spec, ctx):
    """Run a shell command, honouring `capture` and `expect`/`expect_contains` on its stdout.

    A failure reports the exit code and **stderr**, then stdout. Preferring stdout (the old
    behaviour) hid the actual error whenever a script printed progress before dying: a DDL error
    that took `switch-database.sh test` down was logged as nothing but the script's own "Creating
    test.sqlite..." chatter, which says only where it got to, not what went wrong.

    `capture` and `expect` used to be silently ignored here, on the reasoning that a shell step
    *does* something rather than reading something. Several do both, and the silence was expensive:
    `12b` captured the real device PIN with a shell step, so `real_pin` was never set; the restore
    command then went through `shell=True` with `$real_pin` still in it, and **bash** expanded that
    undefined name to an empty string, blanking the PIN in `config.json`. The verification action
    right underneath compared the file against `$real_pin` and would have caught it, except `expect`
    was ignored there too, so the step passed and the next launch could not reach the cube
    (2026-08-10).

    That bash expansion is why an unresolved variable cannot be left to `safe_substitute`'s
    leave-it-alone behaviour: what survives Python gets eaten by the shell. Honouring `expect` is
    what turns it back into a failed assertion instead of silent damage."""
    command = _sub(spec["command"], ctx)
    r = subprocess.run(command, shell=True, capture_output=True, text=True)
    out, err = r.stdout.strip(), r.stderr.strip()
    if r.returncode != 0:
        parts = [f"exit={r.returncode}"]
        if err:
            parts.append(err)
        if out:
            parts.append(f"(stdout before it failed: {out})")
        return StepResult(False, " | ".join(parts))

    expect, expect_contains = _resolve_expect(spec, ctx)
    if expect is not None and out != str(expect):
        return StepResult(
            False,
            f"stdout was {out!r}",
            expected=str(expect),
            actual=out or "(nothing)",
        )
    if expect_contains is not None and expect_contains not in out:
        return StepResult(
            False,
            f"stdout was {out!r}",
            expected=f"contains {expect_contains}",
            actual=out or "(nothing)",
        )
    if "capture" in spec:
        ctx["vars"][spec["capture"]] = out
        _remember_capture(spec, ctx, out)
    return StepResult(True, out or "exit=0")


APP_PROCESS_PATTERN = "TimeFlip.app/Contents/MacOS/TimeFlip"


def app_running():
    r = subprocess.run(["pgrep", "-f", APP_PROCESS_PATTERN], capture_output=True, text=True)
    return r.returncode == 0


def act_quit_app(spec, ctx):
    """Quit the app and wait until its process is really gone.

    `osascript -e 'tell application "TimeFlip" to quit'` returns once the app *acknowledges* the
    quit event, which is not the same as having exited -- and with `pause_on_lock` on, the app
    pauses and locks the device over BLE in `applicationWillTerminate` before it terminates. A step
    that quit and immediately relaunched could therefore start a second instance on top of the
    first (the failure session_setup._quit_app was written to prevent, for the end-of-run restore
    path only). Polling for the process to disappear closes that for every checklist quit, and
    surfaces a quit that never completes (a modal dialog holding it open) as a step failure rather
    than as mysterious behaviour two steps later.

    Quitting an app that isn't running is NOT a no-op in AppleScript -- it can launch the app to
    deliver the event -- so a process that isn't there is reported as already gone instead."""
    if not app_running():
        return StepResult(True, "already not running")
    r = subprocess.run(["osascript", "-e", 'tell application "TimeFlip" to quit'],
                       capture_output=True, text=True)
    timeout = spec.get("timeout_seconds", 30)
    interval = spec.get("poll_interval", 0.5)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not app_running():
            return StepResult(True, "quit, process gone")
        time.sleep(interval)
    stderr = r.stderr.strip()
    return StepResult(
        False,
        f"app still running {timeout}s after the quit was sent" + (f": {stderr}" if stderr else ""),
        expected="the app's process to exit",
        actual=f"still running (after waiting {timeout}s)" + (f" -- osascript said: {stderr}" if stderr else ""),
    )


def _run_osascript_with_retry(script, retries=2, retry_delay=0.6):
    """Back-to-back osascript calls that open/close the status-item menu can race --
    the previous call's menu-close hasn't fully settled before this one opens it again,
    producing a transient "-1719 Invalid index" (confirmed live, not a real permission
    denial -- those error instantly and consistently, this doesn't). Retrying after a
    short delay resolves it; a genuine problem still fails after retries are exhausted."""
    last = None
    for attempt in range(retries + 1):
        last = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if last.returncode == 0 or "-1719" not in last.stderr:
            return last
        time.sleep(retry_delay)
    return last


def act_applescript(spec, ctx):
    """Run an AppleScript against the app, retrying until it works or `timeout_seconds` elapses.

    The retry matters because these scripts read/click a window that may not be there *yet*: a
    Settings window opened by the click before takes a moment to exist, and a script addressing it
    a beat too early fails outright. Steps used to paper over that with a fixed `sleep 1` in front,
    which is both slower than necessary when the window is ready and still too short when the
    machine is busy. Retrying instead means the step continues the moment the element is really
    there. An `expect`/`expect_contains` mismatch retries too (the value may not have landed yet);
    a script with neither succeeds as soon as osascript returns cleanly, so a plain click is done
    on its first try and never repeats."""
    script = _sub(spec["script"], ctx)
    timeout = spec.get("timeout_seconds", 30)
    interval = spec.get("poll_interval", 1)
    deadline = time.time() + timeout
    while True:
        r = _run_osascript_with_retry(script)
        ok = r.returncode == 0
        text = r.stdout.strip() if ok else r.stderr.strip()
        expected = None
        actual = None
        if ok:
            expect, expect_contains = _resolve_expect(spec, ctx)
            if expect is not None:
                ok = text == str(expect)
            elif expect_contains is not None:
                ok = expect_contains in text
            if ok and "capture" in spec:
                ctx["vars"][spec["capture"]] = text
                _remember_capture(spec, ctx, text)
            if not ok:
                expected = str(expect) if expect is not None else f"contains {expect_contains}"
                actual = text or "(nothing)"
        if ok or time.time() >= deadline:
            if not ok and expected is not None:
                actual = f"{actual} (still, after retrying for {timeout}s)"
                text = f"{text} (expected {expected!r})"
            break
        time.sleep(interval)
    # A script that captures or asserts is reading something (a field's contents, a UI state);
    # one that just drives the UI isn't. Checked off `spec` rather than the resolved expect vars,
    # which only exist on the `ok` path.
    reads = any(k in spec for k in ("capture", "expect", "expect_contains"))
    return StepResult(ok, text, value=_pretty_value(text) if (ok and reads and text) else None,
                      expected=expected, actual=actual)


def _resolve_expect(spec, ctx):
    expect = spec.get("expect")
    expect_contains = spec.get("expect_contains")
    if expect is not None:
        expect = _sub(str(expect), ctx)
    if expect_contains is not None:
        expect_contains = _sub(str(expect_contains), ctx)
    return expect, expect_contains


def act_sql_query(spec, ctx):
    query = _sub(spec["query"], ctx)
    rows, cols = _run_sql(ctx["db_path"], query)
    text = _format_rows(rows, cols)
    expect, expect_contains = _resolve_expect(spec, ctx)
    ok = True
    if expect is not None:
        ok = text == str(expect)
    elif expect_contains is not None:
        ok = expect_contains in text
    captured = rows[0][0] if rows and len(rows[0]) == 1 else text
    if "capture" in spec:
        ctx["vars"][spec["capture"]] = captured
        _remember_capture(spec, ctx, captured)
    expected_desc = expect if expect is not None else expect_contains
    detail = f"query result: {text}" + ("" if ok else f" (expected {expected_desc!r})")
    # Only a query that actually reads the app's state is a value worth echoing. A constant
    # `SELECT 'y';` is variable plumbing (it sets a flag a later `when` guard reads), so it
    # stays silent rather than printing a "y" that says nothing about the device.
    reads_state = " from " in query.lower()
    return StepResult(
        ok, detail, captured,
        value=_pretty_value(text) if (ok and reads_state) else None,
        expected=None if ok else (str(expect) if expect is not None else f"contains {expect_contains}"),
        actual=None if ok else text,
    )


def act_sql_exec(spec, ctx):
    """For INSERT/UPDATE -- no rows to compare, just runs and commits."""
    query = _sub(spec["query"], ctx)
    conn = sqlite3.connect(ctx["db_path"])
    try:
        cur = conn.execute(query)
        conn.commit()
        return StepResult(True, f"executed, rowcount={cur.rowcount}")
    finally:
        conn.close()


def act_wait_for_sql(spec, ctx):
    query = _sub(spec["query"], ctx)
    expect, expect_contains = _resolve_expect(spec, ctx)
    timeout = spec.get("timeout_seconds", 30)
    # Poll every second by default: the point of a wait is to continue the moment the value
    # appears, so a coarser cadence only adds dead time to a step that already succeeded. A step
    # waiting on something that moves on a minutes timescale (a battery reading flapping, a
    # Bluetooth drop being noticed) sets a slower `poll_interval` itself.
    interval = spec.get("poll_interval", 1)
    # timeout_seconds = 0 (or negative) means wait *indefinitely* -- for a step gated on a human
    # action (turn Bluetooth off/on, flip the cube) the developer might wander off, and a
    # distraction shouldn't fail the run. It just keeps polling (and re-nudging) until the side
    # effect the step waits on actually shows up. A positive timeout still fails on expiry as before.
    wait_forever = timeout is not None and timeout <= 0
    # Optional prompt: an "action needed" nudge the developer sees when their input is required
    # (e.g. "pair the device", "start flipping"). It is NOT printed the moment the condition is
    # unmet -- after the app is (re)started it takes a few seconds to connect and log its
    # `Login accepted`, and alerting instantly meant every relaunch cried "the device hasn't
    # reconnected" and then passed 2s later. So we poll quietly for a grace period first and only
    # alert if it still hasn't happened by then. `alert_after_seconds` overrides the 5s default.
    #
    # An *indefinite* wait is the exception, and gets no grace period at all: `timeout_seconds = 0`
    # with a prompt means nothing but a hand will ever satisfy this step, so there is no relaunch
    # that might satisfy it on its own and nothing to cry wolf about. Staying quiet there is the
    # opposite of what a `(You)` step needs. Measured 2026-08-12: 08i Scenario A Step 6 (unlock face
    # 8 by hand) polled silently, the developer acted off the step text inside the 5s grace, and the
    # banner the step's own prose calls "the only thing that raises the ACTION NEEDED banner" never
    # appeared -- a person fast enough to beat the grace period is never told they were needed.
    # An explicit `alert_after_seconds` still wins, for a wait that wants a delay either way.
    prompt = spec.get("prompt")
    prompt = _sub(prompt, ctx) if prompt else None
    alert_after = spec.get("alert_after_seconds", 0 if wait_forever else ALERT_AFTER_SECONDS)

    def matched(text):
        if expect is not None:
            return text == str(expect)
        if expect_contains is not None:
            return expect_contains in text
        return False

    rows, cols = _run_sql(ctx["db_path"], query)
    last_text = _format_rows(rows, cols)
    if matched(last_text):
        return StepResult(True, f"already satisfied: {last_text}", value=_pretty_value(last_text))
    started = time.time()
    deadline = None if wait_forever else started + timeout
    alerted = False
    # No grace period means the nudge belongs on screen *before* the first poll, not one
    # `poll_interval` into the wait: the loop only reaches its own alert check after a sleep, so
    # leaving it to fire there would still open with a silent pause on a step asking for a hand.
    if prompt and alert_after <= 0:
        _announce(prompt, ctx)
        alerted = True
    while wait_forever or time.time() < deadline:
        time.sleep(interval)
        rows, cols = _run_sql(ctx["db_path"], query)
        last_text = _format_rows(rows, cols)
        if matched(last_text):
            return StepResult(True, f"matched after poll: {last_text}", value=_pretty_value(last_text))
        # Grace period elapsed and still nothing -- now it's worth a person's attention. Said
        # once, not repeated: a wait can run for minutes (an indefinite one until the developer
        # acts), and re-printing the banner would just push the step it asks about off the screen.
        # Routed through _announce rather than called directly: if this step's actions already
        # put up the banner for an earlier ask_user, _announce prints just the nudge instead of a
        # second banner underneath the first.
        if prompt and not alerted and time.time() - started >= alert_after:
            _announce(prompt, ctx)
            alerted = True
    expected_desc = str(expect) if expect is not None else f"contains {expect_contains}"
    return StepResult(
        False,
        f"timed out after {timeout}s waiting for {expected_desc!r}, last saw: {last_text}",
        expected=expected_desc,
        actual=f"{last_text} (still, after waiting {timeout}s)",
    )


def act_cgevent_click(spec, ctx):
    import Quartz

    target = spec["target"]
    if target not in LOCATORS:
        return StepResult(False, f"unknown cgevent_click target: {target}")
    x, y = LOCATORS[target]()
    mode = spec.get("mode", "single")

    def post(kind, click_state):
        e = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft)
        Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, click_state)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

    if mode == "single":
        post(Quartz.kCGEventLeftMouseDown, 1)
        post(Quartz.kCGEventLeftMouseUp, 1)
    elif mode == "double":
        post(Quartz.kCGEventLeftMouseDown, 1)
        post(Quartz.kCGEventLeftMouseUp, 1)
        time.sleep(0.15)
        post(Quartz.kCGEventLeftMouseDown, 2)
        post(Quartz.kCGEventLeftMouseUp, 2)
    elif mode == "hold":
        hold_seconds = spec.get("hold_seconds", 4)
        post(Quartz.kCGEventLeftMouseDown, 1)
        time.sleep(hold_seconds)
        post(Quartz.kCGEventLeftMouseUp, 1)
    else:
        return StepResult(False, f"unknown cgevent_click mode: {mode}")
    return StepResult(True, f"{mode} click at ({x:.1f}, {y:.1f})")


def act_cgevent_hold_interrupted_by_key(spec, ctx):
    """mouseDown, wait, post a keydown/keyup (e.g. Escape=53) while the mouse is still
    conceptually held (no mouseUp yet), wait again, then mouseUp -- two independent
    synthetic event streams interleaving like two real hands would. See "hold interrupted
    by closing the window" in the auto-pause stepper checklist."""
    import Quartz

    target = spec["target"]
    if target not in LOCATORS:
        return StepResult(False, f"unknown target: {target}")
    x, y = LOCATORS[target]()
    keycode = spec.get("keycode", 53)  # Escape
    before_key_seconds = spec.get("before_key_seconds", 1.0)
    after_key_seconds = spec.get("after_key_seconds", 1.0)

    down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventSetIntegerValueField(down, Quartz.kCGMouseEventClickState, 1)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)

    time.sleep(before_key_seconds)

    key_down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
    key_up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_down)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_up)

    time.sleep(after_key_seconds)

    up = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventSetIntegerValueField(up, Quartz.kCGMouseEventClickState, 1)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)

    return StepResult(True, f"held at ({x:.1f}, {y:.1f}), keycode {keycode} interjected, released")


def act_cgevent_key(spec, ctx):
    """Post a raw keydown/keyup for a key code via CGEvent (default 53 = Escape). Used to dismiss a
    modal status-item dropdown menu a synthetic click opened, without an osascript call that would
    collide with the open menu and hang (see Method 6's warning).

    **The event goes to whatever app is frontmost**, exactly like AppleScript `keystroke` -- it is
    posted to the HID tap, not delivered to a process. That is a real trap in a checklist: any step
    after an `ask_user` runs with the *terminal* frontmost, because the tester just typed y there,
    so the key lands in the terminal and the app never sees it. Cost a live failure on 2026-08-01,
    where an Escape meant for a rename field echoed `^[` into the terminal instead.

    Pass `activate = "TimeFlip"` to bring that app forward first. Left off by default because the
    status-item case must NOT do it: an osascript call while that menu is open is the collision the
    docstring above warns about, and there the click that opened the menu has already made the app
    frontmost anyway."""
    import Quartz
    keycode = spec.get("keycode", 53)
    activate = spec.get("activate")
    if activate:
        subprocess.run(
            ["osascript", "-e", f'tell application "{activate}" to activate'],
            capture_output=True, text=True,
        )
        time.sleep(0.4)
    down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
    up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
    return StepResult(True, f"posted key code {keycode}")


def _menu_item_names(process="TimeFlip"):
    script = f"""
tell application "System Events"
    tell process "{process}"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            set names to name of every menu item of menu 1
        end tell
        key code 53
    end tell
end tell
return names"""
    r = _run_osascript_with_retry(script)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return [n.strip() for n in r.stdout.strip().split(",")]


def _click_menu_item(item_name, process="TimeFlip"):
    script = f"""
tell application "System Events"
    tell process "{process}"
        tell menu bar item 1 of menu bar 2
            click
            delay 0.4
            click menu item "{item_name}" of menu 1
        end tell
    end tell
end tell"""
    r = _run_osascript_with_retry(script)
    return r.returncode == 0, (r.stdout.strip() or r.stderr.strip())


def act_click_menu_item(spec, ctx):
    item_name = _sub(spec["item"], ctx)
    ok, detail = _click_menu_item(item_name)
    return StepResult(ok, detail or f"clicked {item_name!r}")


def act_ensure_unlocked_unpaused(spec, ctx):
    """Precondition resolver: click Unlock (if present) then Resume (if present) to reach a clean
    unlocked+unpaused state. Lock/Unlock and Pause/Resume are mutually-exclusive menu labels
    reflecting live state.

    Crucially, DON'T read the menu just once: the device's lock/pause state can arrive a couple of
    seconds AFTER `Login accepted` (confirmed live -- `lockChanged` landed ~2.5s after login), and
    until it does the menu shows the default "Lock"/"Pause", indistinguishable from a genuinely
    clean device. A single early read therefore misses a locked/paused device and leaves it that
    way (then flips don't register -- a lock freezes face switching). So poll over a settle
    window: click Unlock/Resume whenever they surface, and only conclude "already clean" once the
    menu has stayed free of both for `clean_confirm_seconds` (or `timeout_seconds` elapses).
    `poll_interval`/`clean_confirm_seconds`/`timeout_seconds` are overridable."""
    timeout = spec.get("timeout_seconds", 20)
    interval = spec.get("poll_interval", 1.5)
    clean_confirm = spec.get("clean_confirm_seconds", 6)
    actions_taken = []
    clean_since = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        names = _menu_item_names()
        acted = False
        if "Unlock" in names:
            ok, detail = _click_menu_item("Unlock")
            if not ok:
                return StepResult(False, f"failed clicking Unlock: {detail}")
            actions_taken.append("Unlock")
            acted = True
            time.sleep(1)
            names = _menu_item_names()
        if "Resume" in names:
            ok, detail = _click_menu_item("Resume")
            if not ok:
                return StepResult(False, f"failed clicking Resume: {detail}")
            actions_taken.append("Resume")
            acted = True
        if acted:
            clean_since = None  # state just changed -- restart the stable-clean clock
        elif clean_since is None:
            clean_since = time.time()
        elif time.time() - clean_since >= clean_confirm:
            break
        time.sleep(interval)
    detail = "already clean" if not actions_taken else f"clicked: {', '.join(actions_taken)}"
    return StepResult(True, detail)


def act_build_device_history(spec, ctx):
    """Click the status item's right half until the device's own event counter reaches `target`.

    Each pause ends the interval the device is recording and each unpause opens another, so it
    allocates a fresh event number per toggle -- which is what `01b` needs. That checklist resumes a
    history fetch *from an event number*, so the counter is the thing that has to climb; a row count
    would not do.

    This used to be ten physical flips: a prompt, and a poll with no timeout, while somebody turned
    the cube over and over. The cube does not have to move to produce history, and the intervals a
    toggle produces are the *harmless* kind: `convertEligibleEvents` filters on `paused = 0`, so
    every second one never becomes a `time_entry` and cannot land in the totals `10b` and `11b`
    measure, where ten real flips onto real faces could (see Step 17's bug entry, where a 9-second
    flip onto face 5 read as fixture damage).

    **A loop, not a computed click count.** It was computed first, and the arithmetic was sound: the
    shortfall, rounded up to whatever parity left the device unpaused. The parity was the only reason
    for it, and leaving the device unpaused is the *next* step's job, so once that moved out there
    was nothing left for the calculation to buy. A loop also cannot be wrong about how many event
    numbers a toggle produces, which any calculation has to assume: measured 2026-08-12, six clicks
    against a counter of 4 left it reading 11.

    `click_gap_seconds` has a floor rather than a preference behind it: a `togglePause` fires
    `NSEvent.doubleClickInterval` after the click that scheduled it (`MenuBarController`), so the
    gap has to exceed that or a click lands while the previous toggle is still pending. 1s clears
    the 0.5s default. It is not a double-click hazard -- `cgevent_click` posts an explicit
    `clickState` of 1, so each arrives as `clickCount=1` -- but the `-> lockDevice` check below
    proves that rather than trusting it, because a click read as a lock would freeze face switching
    for every checklist that follows.

    Reads only real rows (`event_number < 900000`). The seeded report fixture numbers from 900001,
    and a fixture row read as the newest would satisfy any target instantly -- the same trap
    `Method 24.k` exists for.
    """
    target = int(spec.get("target", 10))
    gap = float(spec.get("click_gap_seconds", 1.0))
    settle = float(spec.get("settle_seconds", 6))
    max_clicks = int(spec.get("max_clicks", 25))
    db_path = ctx["db_path"]

    def counter():
        rows, _ = _run_sql(db_path, (
            "SELECT COALESCE((SELECT event_number FROM device_event "
            "WHERE event_number < 900000 ORDER BY device_event_id DESC LIMIT 1), 0);"
        ))
        return int(rows[0][0]) if rows and rows[0][0] is not None else 0

    def log_head():
        rows, _ = _run_sql(db_path, "SELECT COALESCE(MAX(debug_log_id), 0) FROM debug_log;")
        return int(rows[0][0]) if rows else 0

    names = _menu_item_names()
    if "Pause" not in names and "Resume" not in names:
        return StepResult(
            False,
            f"the dropdown offers neither Pause nor Resume ({', '.join(names)}) -- there is no "
            "device to pause, so no history can be built",
        )
    started_at = counter()
    if started_at >= target:
        return StepResult(True, f"event counter already {started_at} (target {target})",
                          value=str(started_at))

    baseline = log_head()
    clicked = 0

    def clicks_logged_since(log_id):
        rows, _ = _run_sql(db_path, (
            "SELECT COUNT(*) FROM debug_log WHERE tag='click' "
            f"AND debug_log_id > {log_id} AND message LIKE 'Status item clicked:%';"
        ))
        return int(rows[0][0]) if rows else 0

    def click_once():
        """One right-half click, confirmed to have landed.

        Confirmed rather than assumed, because one silently did not: measured 2026-08-12, six clicks
        were posted and five reached `handleStatusItemClick`. The status item's width tracks its own
        title, and pausing changes that title, so the point computed from the previous layout can
        fall outside the item -- the locator is re-read per click, but the app has not necessarily
        re-laid out by then. The app logs every click it receives, so a missing line is the signal,
        and one retry is enough for a layout that has since settled.
        """
        nonlocal clicked
        for attempt in (1, 2):
            before = log_head()
            result = act_cgevent_click({"target": "status_item_right", "mode": "single"}, ctx)
            if not result.success:
                return False, result.detail
            time.sleep(gap)
            if clicks_logged_since(before):
                clicked += 1
                return True, None
            if attempt == 2:
                return False, "the click did not reach the app (no 'Status item clicked' line), twice"
        return False, "unreachable"

    while True:
        current = counter()
        if current >= target:
            break
        if clicked >= max_clicks:
            return StepResult(
                False,
                f"event counter reached {current} of {target} after {max_clicks} clicks -- giving up "
                "rather than clicking forever. Is the device still connected?",
            )
        ok, detail = click_once()
        if not ok:
            return StepResult(False, f"click {clicked + 1} failed: {detail}")
        # The app refreshes history straight after a pause toggle, so the row lands in a second or
        # two. Poll for it, then click again regardless: a toggle that produced no new number is not
        # an error, it just means another click is needed.
        deadline = time.time() + settle
        while time.time() < deadline and counter() == current:
            time.sleep(1)

    finished_at = counter()
    rows, _ = _run_sql(db_path, (
        "SELECT COUNT(*), SUM(message LIKE '%-> lockDevice%') FROM debug_log "
        f"WHERE tag='click' AND debug_log_id > {baseline} AND message LIKE 'Status item clicked:%';"
    ))
    landed, locks = (rows[0][0] or 0, rows[0][1] or 0) if rows else (0, 0)
    if locks:
        return StepResult(False, f"{locks} of {clicked} clicks resolved to lockDevice, not togglePause -- "
                                 f"raise click_gap_seconds above NSEvent.doubleClickInterval")
    # The counter is the whole gate, and the loop above is the only way out of it, so there is nothing
    # left to assert here. Whether the device ended up paused is deliberately not asked: it is the
    # next step's question, and asking it here -- once, and fatally -- is what halted a run at a
    # perfectly good counter of 11 on 2026-08-12.
    return StepResult(
        True,
        f"event counter {started_at} -> {finished_at} (target {target}) via {clicked} right-half "
        f"clicks, {landed} logged",
        value=str(finished_at),
    )


def act_ask_user(spec, ctx):
    """A real yes/no question -- 'y' passes, 'n' fails (any case), and anything else
    (a stray keystroke, a blank Enter) re-prompts instead of being silently treated
    as either answer, so an accidental key can't flip the result. Input is lowercased
    before comparison, so 'Y'/'N' work too. See ask_user_or_detect for the polling
    variant, and confirm_warning() in session_setup.py for the same loop-until-valid
    pattern applied to the initial acknowledgment gate.

    With `capture`, the question is a *branch*, not a gate: the 'y'/'n' is stored in that
    var (for a later `when` guard to read) and the step always succeeds -- 'n' is a valid
    choice, not a failure. Without `capture`, 'n' fails the step as before."""
    prompt = _sub(spec["prompt"], ctx)
    _announce(prompt, ctx)
    while True:
        answer = input(">>> y/n: ").strip().lower()
        if answer in ("y", "n"):
            if "capture" in spec:
                ctx["vars"][spec["capture"]] = answer
                _remember_capture(spec, ctx, answer)
                return StepResult(True, f"user answered {answer}", value=answer)
            if answer == "y":
                return StepResult(True, "user answered y", value="y")
            return StepResult(False, "user answered n", expected="y", actual="n")
        print(f"Not recognized: {answer!r} -- please answer 'y' or 'n'.")


def act_ask_user_or_detect(spec, ctx):
    """Poll a DB query for a change instead of asking for confirmation -- see
    "Detect a physical action instead of asking" in Tests/Methods.md."""
    prompt = _sub(spec["prompt"], ctx)
    query = _sub(spec["detect_query"], ctx)
    timeout = spec.get("timeout_seconds", 120)
    interval = spec.get("poll_interval", 1)  # see act_wait_for_sql
    # timeout_seconds = 0 (or negative) waits indefinitely -- for a physical action (flip the cube)
    # the developer can take as long as they like; a distraction shouldn't fail the run. See the
    # matching note in act_wait_for_sql.
    wait_forever = timeout is not None and timeout <= 0
    rows, cols = _run_sql(ctx["db_path"], query)
    baseline = _format_rows(rows, cols)
    _announce(prompt, ctx)
    print(">>> (auto-detecting via the database -- no need to press Enter)")
    deadline = None if wait_forever else time.time() + timeout
    while wait_forever or time.time() < deadline:
        rows, cols = _run_sql(ctx["db_path"], query)
        current = _format_rows(rows, cols)
        if current != baseline:
            return StepResult(True, f"detected change: {baseline} -> {current}",
                              value=f"{_pretty_value(baseline)} -> {_pretty_value(current)}")
        time.sleep(interval)
    return StepResult(
        False,
        f"timed out after {timeout}s waiting for a change from {baseline}",
        expected=f"any change from {baseline}",
        actual=f"{baseline} (unchanged, after waiting {timeout}s)",
    )


def act_cgevent_click_element(spec, ctx):
    """Coordinate-click the CENTER of an accessibility element -- for SwiftUI controls that respond
    only to a real mouse click, e.g. a `Text` + `.onTapGesture` row that an AX `click`/AXPress
    doesn't actuate (the discovered-device pairing row). Reads the element's `position`+`size` via
    System Events, then CGEvent-clicks the middle. `element` is a System Events element reference
    relative to the target `process` (default TimeFlip), e.g.
    `first static text of group 3 of ... whose name contains "TimeFlip"`.

    Locating the element retries until it's found or `timeout_seconds` elapses -- the row this
    clicks often appears a few seconds after the action that produces it (a BLE scan result, a
    freshly-opened window), so a single early read would fail on something that was about to
    work. Only the *read* retries; the click happens once, after the element is really there."""
    import Quartz

    element = _sub(spec["element"], ctx)
    process = spec.get("process", "TimeFlip")
    frame_script = f'''tell application "System Events"
    tell process "{process}"
        set el to {element}
        set p to position of el
        set s to size of el
        return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
    end tell
end tell'''
    timeout = spec.get("timeout_seconds", 30)
    interval = spec.get("poll_interval", 1)
    deadline = time.time() + timeout
    while True:
        r = _run_osascript_with_retry(frame_script)
        if r.returncode == 0 or time.time() >= deadline:
            break
        time.sleep(interval)
    if r.returncode != 0:
        return StepResult(
            False,
            f"couldn't locate element {element!r} within {timeout}s: {r.stderr.strip()}",
            expected=f"element {element} to exist",
            actual=f"not found (still, after retrying for {timeout}s)",
        )
    try:
        x, y, w, h = (float(v) for v in r.stdout.strip().split(","))
    except ValueError:
        return StepResult(False, f"unexpected element frame: {r.stdout.strip()!r}")
    cx, cy = x + w / 2, y + h / 2

    def post(kind):
        e = Quartz.CGEventCreateMouseEvent(None, kind, (cx, cy), Quartz.kCGMouseButtonLeft)
        Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, 1)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

    post(Quartz.kCGEventLeftMouseDown)
    post(Quartz.kCGEventLeftMouseUp)
    return StepResult(True, f"cgevent-clicked element center ({cx:.0f},{cy:.0f})")


def act_cgevent_context_menu_pick(spec, ctx):
    """Right-click an accessibility element, then click an item in the context menu it opens.

    A SwiftUI `.contextMenu` is **invisible to accessibility**: the element advertises an
    `AXShowMenu` action that performs without error and opens nothing, and once a real right-click
    has opened the menu, `count of menus` still reports 0 on both the element and the process. The
    menu is genuinely on screen -- confirmed by screenshot on 2026-08-01 against the Categories tab's
    name column -- so the only way to drive it is by coordinate.

    The menu's top-left lands at the click point, so an item is reached by offsetting from there:
    `item_dx`/`item_dy` default to the first item of a single-item menu. A menu with more items
    needs the offset stepped by its row height, which has to be measured rather than assumed.

    `anchor` picks where in the element to right-click, as a fraction of its width: the default
    0.9 lands near the right-hand end, which is the part of a fixed-width column a short label does
    not cover -- the hit area a `contentShape(Rectangle())` exists to claim.
    """
    import Quartz

    element = _sub(spec["element"], ctx)
    process = spec.get("process", "TimeFlip")
    frame_script = f"""tell application "System Events"
    tell process "{process}"
        set el to {element}
        set p to position of el
        set s to size of el
        return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
    end tell
end tell"""
    r = _run_osascript_with_retry(frame_script)
    if r.returncode != 0:
        return StepResult(
            False,
            f"couldn't locate element {element!r}: {r.stderr.strip()}",
            expected=f"element {element} to exist",
            actual="not found",
        )
    try:
        x, y, w, h = (float(v) for v in r.stdout.strip().split(","))
    except ValueError:
        return StepResult(False, f"unexpected element frame: {r.stdout.strip()!r}")

    # `anchor_dx` is a pixel offset applied after the anchor, for a target that is not inside any
    # element at all: the bare middle of a `LabeledContent` row, which belongs to the row's
    # `contentShape` and is exposed to accessibility only as the label and value either side of it.
    # Expressing that as a fraction of the label's width would be a number that changes whenever the
    # label's text does.
    anchor = float(spec.get("anchor", 0.9))
    ax, ay = x + w * anchor + float(spec.get("anchor_dx", 0)), y + h / 2

    def post(kind, point, button):
        e = Quartz.CGEventCreateMouseEvent(None, kind, point, button)
        Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, 1)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
        time.sleep(0.08)

    post(Quartz.kCGEventRightMouseDown, (ax, ay), Quartz.kCGMouseButtonRight)
    post(Quartz.kCGEventRightMouseUp, (ax, ay), Quartz.kCGMouseButtonRight)
    time.sleep(float(spec.get("menu_delay", 1.0)))

    item = (ax + float(spec.get("item_dx", 30)), ay + float(spec.get("item_dy", 12)))
    post(Quartz.kCGEventMouseMoved, item, 0)
    post(Quartz.kCGEventLeftMouseDown, item, Quartz.kCGMouseButtonLeft)
    post(Quartz.kCGEventLeftMouseUp, item, Quartz.kCGMouseButtonLeft)
    return StepResult(
        True,
        f"right-clicked ({ax:.0f},{ay:.0f}), picked menu item at ({item[0]:.0f},{item[1]:.0f})",
    )


ACTIONS = {
    "shell": act_shell,
    "quit_app": act_quit_app,
    "applescript": act_applescript,
    "sql_query": act_sql_query,
    "sql_exec": act_sql_exec,
    "wait_for_sql": act_wait_for_sql,
    "cgevent_click": act_cgevent_click,
    "cgevent_click_element": act_cgevent_click_element,
    "cgevent_context_menu_pick": act_cgevent_context_menu_pick,
    "cgevent_hold_interrupted_by_key": act_cgevent_hold_interrupted_by_key,
    "cgevent_key": act_cgevent_key,
    "click_menu_item": act_click_menu_item,
    "ensure_unlocked_unpaused": act_ensure_unlocked_unpaused,
    "build_device_history": act_build_device_history,
    "ask_user": act_ask_user,
    "ask_user_or_detect": act_ask_user_or_detect,
}


def _run_single(spec, ctx):
    action = spec.get("action")
    fn = ACTIONS.get(action)
    if fn is None:
        return StepResult(False, f"unknown action type: {action!r}")
    try:
        return fn(spec, ctx)
    except Exception as e:  # noqa: BLE001 -- a step failure must not crash the whole run
        return StepResult(False, f"exception: {e}")


def capture_names(spec):
    """The `capture` var names a step declares -- a single action's `capture`, or every
    `capture` across an `[[actions]]` sequence -- so the runner can log the values left
    under them in ctx["vars"] after the step runs."""
    if "actions" in spec:
        return [s["capture"] for s in spec["actions"] if "capture" in s]
    return [spec["capture"]] if "capture" in spec else []


def run_step(spec, ctx):
    """A checklist item can be one action, or `[[actions]]` -- a sequence run in order,
    stopping at the first failure (e.g. "click, then confirm via debug_log" is one
    checkbox in the .md but two actions here)."""
    if "actions" in spec:
        details = []
        values = []
        last_captured = None
        for sub in spec["actions"]:
            cond = sub.get("when")
            if cond is not None and not condition_met(cond, ctx):
                details.append(f"skipped (when {cond})")
                continue
            r = _run_single(sub, ctx)
            details.append(r.detail)
            if r.value:
                values.append(r.value)
            last_captured = r.captured
            if not r.success:
                # The failing action's expected/actual is what the reader needs; `detail` still
                # carries the whole sequence for the log.
                return StepResult(False, " | ".join(details), expected=r.expected, actual=r.actual)
        # Every value the sequence read, in order -- a step that only clicks/sleeps contributes
        # none, and its `step_value` row is recorded with a NULL value.
        return StepResult(True, " | ".join(details), last_captured,
                          value=", ".join(values) if values else None)
    return _run_single(spec, ctx)
