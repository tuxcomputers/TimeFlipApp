"""Shared step bodies, read from the ```toml method fences in `Tests/Methods.md`.

A technique used by many steps (launch the app, quit it, confirm the device reconnected, click a
menu item, switch Settings tabs) is written **once**, inside the `## Method N` section that already
documents it in prose, and referenced from a step with `use`:

```toml step
use = "method-3"
capture = "before_quit_id"
```

So the Method link a checklist step already cites is the thing it actually runs -- the prose and the
behaviour can't drift apart, and changing how the app is launched is a one-line edit in one file
rather than 15 copies of a `nohup` command.

A method that collects many variants of one technique (Method 24, "Query the DB") holds them as
named sub-blocks instead of burning a method number on each, and a step names one with a dotted
reference -- `use = "method-24.b"`, written `Method 24.b` in the prose:

```toml method
[a]
action = "sql_query"
query = "SELECT setting_value FROM setting WHERE setting_name='db_type';"

[b]
action = "sql_query"
query = "SELECT MAX(debug_log_id) FROM debug_log;"
```

Resolution rules (see resolve_uses):
- `use = "method-3"`, `use = "3"` and `use = 3` all name Method 3; `use = "method-24.b"` and
  `use = "24.b"` both name Method 24's sub-block `b`.
- The step's OTHER keys are both (a) substituted for `$name` placeholders inside the method's own
  strings and (b) overlaid on top of the method's keys. So a method can be parameterised
  (`item = "Settings..."` fills the method's `$item`) and extended (`capture = "..."`,
  `when = "..."`, `timeout_seconds = 45` on a method that doesn't mention them).
- A method whose block is itself an `[[actions]]` sequence expands to those actions in place.
- `use` works at step level and inside an `[[actions]]` entry, so a step can mix shared and
  bespoke actions.
"""

import copy
import os
import re
import tomllib
from string import Template

ANCHOR_RE = re.compile(r'^<a id="(method-\d+)"></a>\s*$')
FENCE_START_RE = re.compile(r"^```toml method\s*$")
FENCE_END_RE = re.compile(r"^```\s*$")


def methods_path(repo_root):
    return os.path.join(repo_root, "Tests", "Methods.md")


def load_methods(path):
    """`{"method-3": {...spec...}}` for every ```toml method fence in Methods.md, keyed by the
    `<a id="method-N">` anchor the fence sits under."""
    with open(path, "r") as f:
        lines = f.read().splitlines()
    methods = {}
    current = None
    i = 0
    while i < len(lines):
        anchor = ANCHOR_RE.match(lines[i])
        if anchor:
            current = anchor.group(1)
            i += 1
            continue
        if FENCE_START_RE.match(lines[i]):
            j = i + 1
            while j < len(lines) and not FENCE_END_RE.match(lines[j]):
                j += 1
            body = "\n".join(lines[i + 1 : j])
            if current is None:
                raise ValueError(f"{path}: ```toml method block at line {i + 1} has no method anchor above it")
            if current in methods:
                raise ValueError(f"{path}: {current} has more than one ```toml method block")
            try:
                methods[current] = tomllib.loads(body)
            except Exception as e:  # noqa: BLE001 -- point at the offending method, not a stack trace
                raise ValueError(f"{path}: bad TOML in {current}'s method block: {e}") from e
            i = j + 1
            continue
        i += 1
    return methods


def _key(name):
    """`("method-3", None)` from any of `3`, `"3"`, `"method-3"`; `("method-24", "b")` from
    `"24.b"` / `"method-24.b"`."""
    text = str(name).strip()
    head, _, sub = text.partition(".")
    head = head if head.startswith("method-") else f"method-{head}"
    return head, (sub or None)


def _is_container(block):
    """A method holding named sub-blocks (Method 24's `[a]`, `[b]`, ...) rather than one spec: it
    declares no action of its own and every value is a table."""
    if not block or any(k in block for k in ("action", "actions", "use")):
        return False
    return all(isinstance(v, dict) for v in block.values())


def _fill(value, args):
    """Substitute the step's args for `$name` placeholders, at any depth. Unknown placeholders are
    left alone (`safe_substitute`) -- they're the run-time `$vars` the action resolves later
    against ctx (e.g. `$current_log_id`)."""
    if isinstance(value, str):
        return Template(value).safe_substitute(args)
    if isinstance(value, list):
        return [_fill(v, args) for v in value]
    if isinstance(value, dict):
        return {k: _fill(v, args) for k, v in value.items()}
    return value


def _merge(base, args):
    merged = {k: _fill(v, args) for k, v in base.items()}
    merged.update(args)  # the step's own keys win over the method's
    return merged


def _resolve_one(spec, methods):
    """A single action/step dict -> itself, the method it names, or the method's action list."""
    if "use" not in spec:
        return spec
    key, sub = _key(spec["use"])
    if key not in methods:
        raise ValueError(
            f"step references {spec['use']!r} but Tests/Methods.md has no ```toml method block "
            f"for {key} (methods with one: {', '.join(sorted(methods)) or 'none'})"
        )
    args = {k: v for k, v in spec.items() if k != "use"}
    base = copy.deepcopy(methods[key])
    if _is_container(base):
        if sub is None:
            raise ValueError(
                f"{key} holds named sub-blocks, so a step must name one "
                f"(e.g. use = \"{key.removeprefix('method-')}.{sorted(base)[0]}\"); "
                f"available: {', '.join(sorted(base))}"
            )
        if sub not in base:
            raise ValueError(
                f"{key} has no sub-block {sub!r} (available: {', '.join(sorted(base))})"
            )
        base = base[sub]
    elif sub is not None:
        raise ValueError(f"{key} is a single method, so {spec['use']!r} can't name a sub-block")
    if "actions" in base:
        return [_merge(a, args) for a in base["actions"]]
    return _merge(base, args)


def resolve_uses(spec, methods):
    """Expand every `use` in a parsed step spec. Returns a new spec; a spec with no `use`
    anywhere comes back unchanged, so this is safe to call on everything."""
    if not spec:
        return spec
    if "actions" in spec:
        out = {k: v for k, v in spec.items() if k != "actions"}
        actions = []
        for action in spec["actions"]:
            resolved = _resolve_one(action, methods)
            actions.extend(resolved if isinstance(resolved, list) else [resolved])
        out["actions"] = actions
        return out
    resolved = _resolve_one(spec, methods)
    if isinstance(resolved, list):
        # A step-level `use` naming a multi-action method becomes that sequence, keeping any
        # step-level `when` guard on the outside.
        out = {"actions": resolved}
        if "when" in spec:
            out["when"] = spec["when"]
        return out
    return resolved
