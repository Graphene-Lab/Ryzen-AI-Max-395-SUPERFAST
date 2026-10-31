#!/usr/bin/env python3
"""Compare two captured completion requests and report where they diverge.

The engine keeps the KV up to the longest common token prefix, so the first
difference is exactly the point from which a turn pays a fresh prefill. The
report names the message it falls in, because a divergence in the system
prompt costs the whole history and a divergence in the last user message costs
nothing.

    python tools/payload-diff.py a.json b.json [c.json ...]
"""

import json
import sys


def flat(body):
    """The prompt as the engine sees it: one string per message, in order."""
    p = body.get("params", body)
    out = []
    for m in p.get("messages") or []:
        content = m.get("content")
        if isinstance(content, list):
            content = "".join(c.get("text", "") if isinstance(c, dict) else str(c) for c in content)
        out.append((m.get("role", "?"), content or ""))
    return p, out


def common(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def main(paths):
    bodies = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            bodies.append(json.load(f))
    base_params, base = flat(bodies[0])
    print("tool count:", len(base_params.get("tools") or []), "| keys:", ",".join(sorted(base_params)))

    for i in range(1, len(bodies)):
        params, msgs = flat(bodies[i])
        head = min(len(base), len(msgs))
        same = 0
        while same < head and base[same] == msgs[same]:
            same += 1
        shared = sum(len(c) for _, c in base[:same])
        total = sum(len(c) for _, c in base)
        print("\n%s -> %s" % (paths[i - 1], paths[i]))
        print("  messages: %d -> %d, identical leading messages: %d" % (len(base), len(msgs), same))
        print("  tools changed: %s" % ("yes" if (params.get("tools") or []) != (base_params.get("tools") or []) else "no"))
        if same < head:
            role = base[same][0]
            a, b = base[same][1], msgs[same][1]
            at = common(a, b)
            print("  first divergence in message #%d (role %s) at char %d" % (same, role, at))
            print("    shared before it: %d of %d chars (%.1f%%)" % (shared + at, total, 100.0 * (shared + at) / max(total, 1)))
            print("    was: %r" % a[max(0, at - 90):at + 90])
            print("    now: %r" % b[max(0, at - 90):at + 90])
        else:
            print("  no divergence in the shared messages, the prompt is a pure append")
        base, base_params = msgs, params


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        sys.exit(0)
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1:])
