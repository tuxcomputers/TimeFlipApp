"""Action-type registry: each function executes one checklist step's TOML spec.

Every action returns a StepResult(success, detail, captured). `ctx` is a shared dict
carrying `db_path` and `vars` (a name -> value store steps can write to via `capture`
and read from via `$name` placeholders in query/command/script/expect strings).

`$name` (string.Template), not Python str.format's `{name}`, is deliberate: query text
routinely contains literal JSON like `{"enabled":false}`, which `.format()` misparses as
a field placeholder and crashes on. `$name` doesn't collide with `{`/`}` at all.
"""

import subprocess
import sqlite3
import time
from dataclasses import dataclass
from string import Template
from typing import Any, Optional

from locators import LOCATORS


@dataclass
class StepResult:
    success: bool
    detail: str
    captured: Optional[Any] = None


def _sub(text, ctx):
    return Template(text).safe_substitute(ctx["vars"])


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


def act_applescript(spec, ctx):
    script = _sub(spec["script"], ctx)
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
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
        return StepResult(True, f"executed, rowcount={cur.rowcount}")
    finally:
        conn.close()


def act_wait_for_sql(spec, ctx):
    query = _sub(spec["query"], ctx)
    expect, expect_contains = _resolve_expect(spec, ctx)
    timeout = spec.get("timeout_seconds", 30)
    interval = spec.get("poll_interval", 2)
    deadline = time.time() + timeout
    last_text = "(no rows)"
    while time.time() < deadline:
        rows, cols = _run_sql(ctx["db_path"], query)
        last_text = _format_rows(rows, cols)
        if expect is not None and last_text == str(expect):
            return StepResult(True, f"matched after poll: {last_text}")
        if expect_contains is not None and expect_contains in last_text:
            return StepResult(True, f"matched after poll: {last_text}")
        time.sleep(interval)
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
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
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
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
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
    prompt = _sub(spec["prompt"], ctx)
    print(f"\n>>> ACTION NEEDED: {prompt}")
    input(">>> Press Enter once done... ")
    return StepResult(True, "user confirmed")


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


def run_step(spec, ctx):
    """A checklist item can be one action, or `[[actions]]` -- a sequence run in order,
    stopping at the first failure (e.g. "click, then confirm via debug_log" is one
    checkbox in the .md but two actions here)."""
    if "actions" in spec:
        details = []
        last_captured = None
        for sub in spec["actions"]:
            r = _run_single(sub, ctx)
            details.append(r.detail)
            last_captured = r.captured
            if not r.success:
                return StepResult(False, " | ".join(details))
        return StepResult(True, " | ".join(details), last_captured)
    return _run_single(spec, ctx)
