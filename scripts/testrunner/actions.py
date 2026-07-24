"""Action-type registry: each function executes one checklist step's TOML spec.

Every action returns a StepResult(success, detail, captured). `ctx` is a shared dict
carrying `db_path` and `vars` (a name -> value store steps can write to via `capture`
and read from via `$name` placeholders in query/command/script/expect strings).

`$name` (string.Template), not Python str.format's `{name}`, is deliberate: query text
routinely contains literal JSON like `{"enabled":false}`, which `.format()` misparses as
a field placeholder and crashes on. `$name` doesn't collide with `{`/`}` at all.
"""

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


def _sub(text, ctx):
    return Template(text).safe_substitute(ctx["vars"])


def _remember_capture(spec, ctx, value):
    """Mirror a just-captured value into logs/00-remembered.json, if a recorder is wired in.
    `remember = "changed"` (with `restores = "<setting>"`) routes it to the changed bucket;
    any other capture goes to recorded. No-op when no recorder is attached (e.g. unit tests)."""
    rec = ctx.get("remembered")
    if rec is not None:
        rec.record_capture(spec, value, ctx.get("db_path"))


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
    command = _sub(spec["command"], ctx)
    r = subprocess.run(command, shell=True, capture_output=True, text=True)
    ok = r.returncode == 0
    detail = (r.stdout.strip() or r.stderr.strip() or f"exit={r.returncode}")
    return StepResult(ok, detail)


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
    script = _sub(spec["script"], ctx)
    r = _run_osascript_with_retry(script)
    ok = r.returncode == 0
    text = r.stdout.strip() if ok else r.stderr.strip()
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
            expected_desc = expect if expect is not None else expect_contains
            text = f"{text} (expected {expected_desc!r})"
    return StepResult(ok, text)


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
    return StepResult(ok, detail, captured)


def act_sql_exec(spec, ctx):
    """For INSERT/UPDATE -- no rows to compare, just runs and commits."""
    query = _sub(spec["query"], ctx)
    conn = sqlite3.connect(ctx["db_path"])
    try:
        cur = conn.execute(query)
        conn.commit()
        # A mutating statement may have changed a setting we're tracking in `changed`; refresh
        # its live `current` now rather than waiting for the next capture.
        rec = ctx.get("remembered")
        if rec is not None:
            rec.flush(ctx.get("db_path"))
        return StepResult(True, f"executed, rowcount={cur.rowcount}")
    finally:
        conn.close()


def act_wait_for_sql(spec, ctx):
    query = _sub(spec["query"], ctx)
    expect, expect_contains = _resolve_expect(spec, ctx)
    timeout = spec.get("timeout_seconds", 30)
    interval = spec.get("poll_interval", 2)
    # Optional prompt: printed ONLY if the condition isn't already met, right before we start
    # polling -- i.e. an "action needed" nudge the developer sees exactly when their input is
    # required (e.g. "start flipping the device"), and never when it's already satisfied.
    prompt = spec.get("prompt")
    prompt = _sub(prompt, ctx) if prompt else None

    def matched(text):
        if expect is not None:
            return text == str(expect)
        if expect_contains is not None:
            return expect_contains in text
        return False

    rows, cols = _run_sql(ctx["db_path"], query)
    last_text = _format_rows(rows, cols)
    if matched(last_text):
        return StepResult(True, f"already satisfied: {last_text}")
    if prompt:
        print(f"\n>>> ACTION NEEDED: {prompt}")
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(interval)
        rows, cols = _run_sql(ctx["db_path"], query)
        last_text = _format_rows(rows, cols)
        if matched(last_text):
            return StepResult(True, f"matched after poll: {last_text}")
    expected_desc = expect if expect is not None else expect_contains
    return StepResult(False, f"timed out after {timeout}s waiting for {expected_desc!r}, last saw: {last_text}")


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
    """Precondition resolver: Lock/Unlock and Pause/Resume are mutually-exclusive menu
    item labels reflecting live state, so idempotently clicking Unlock (if present) then
    Resume (if present) reaches a clean unlocked+unpaused state from any starting point."""
    actions_taken = []
    names = _menu_item_names()
    if "Unlock" in names:
        ok, detail = _click_menu_item("Unlock")
        if not ok:
            return StepResult(False, f"failed clicking Unlock: {detail}")
        actions_taken.append("Unlock")
        time.sleep(1)
        names = _menu_item_names()
    if "Resume" in names:
        ok, detail = _click_menu_item("Resume")
        if not ok:
            return StepResult(False, f"failed clicking Resume: {detail}")
        actions_taken.append("Resume")
        time.sleep(1)
    detail = "already clean" if not actions_taken else f"clicked: {', '.join(actions_taken)}"
    return StepResult(True, detail)


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
    print(f"\n>>> ACTION NEEDED: {prompt}")
    while True:
        answer = input(">>> y/n: ").strip().lower()
        if answer in ("y", "n"):
            if "capture" in spec:
                ctx["vars"][spec["capture"]] = answer
                _remember_capture(spec, ctx, answer)
                return StepResult(True, f"user answered {answer}")
            return StepResult(answer == "y", f"user answered {answer}")
        print(f"Not recognized: {answer!r} -- please answer 'y' or 'n'.")


def act_ask_user_or_detect(spec, ctx):
    """Poll a DB query for a change instead of asking for confirmation -- see
    "Detect a physical action instead of asking" in Tests/Methods.md."""
    prompt = _sub(spec["prompt"], ctx)
    query = _sub(spec["detect_query"], ctx)
    timeout = spec.get("timeout_seconds", 120)
    interval = spec.get("poll_interval", 2)
    rows, cols = _run_sql(ctx["db_path"], query)
    baseline = _format_rows(rows, cols)
    print(f"\n>>> ACTION NEEDED: {prompt}")
    print(">>> (auto-detecting via the database -- no need to press Enter)")
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows, cols = _run_sql(ctx["db_path"], query)
        current = _format_rows(rows, cols)
        if current != baseline:
            return StepResult(True, f"detected change: {baseline} -> {current}")
        time.sleep(interval)
    return StepResult(False, f"timed out after {timeout}s waiting for a change from {baseline}")


ACTIONS = {
    "shell": act_shell,
    "applescript": act_applescript,
    "sql_query": act_sql_query,
    "sql_exec": act_sql_exec,
    "wait_for_sql": act_wait_for_sql,
    "cgevent_click": act_cgevent_click,
    "cgevent_hold_interrupted_by_key": act_cgevent_hold_interrupted_by_key,
    "click_menu_item": act_click_menu_item,
    "ensure_unlocked_unpaused": act_ensure_unlocked_unpaused,
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
        last_captured = None
        for sub in spec["actions"]:
            cond = sub.get("when")
            if cond is not None and not condition_met(cond, ctx):
                details.append(f"skipped (when {cond})")
                continue
            r = _run_single(sub, ctx)
            details.append(r.detail)
            last_captured = r.captured
            if not r.success:
                return StepResult(False, " | ".join(details))
        return StepResult(True, " | ".join(details), last_captured)
    return _run_single(spec, ctx)
