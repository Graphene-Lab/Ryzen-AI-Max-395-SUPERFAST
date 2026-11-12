"""Run MultiPL-E human-eval-cs against an OpenAI-compatible endpoint.

Assembly per task: prompt + completion + tests, compiled and run with dotnet.
Debug.Assert failures terminate the process with a non-zero code.

The endpoint serves whichever profile is loaded and ignores the "model" field,
so a run is only meaningful when the served model is the requested one. This
script asks /v1/models before the first task and again every GUARD_EVERY tasks,
aborts on a mismatch, and records the served id in every row: a file that says
"model": "x" and "served": "y" is the fingerprint of a forgotten profile switch.
"""

import argparse
import json
import os
import re
import subprocess
import time
import urllib.request

BASE = os.environ.get("MPE_BASE", "http://192.168.43.253:8741/v1")
KEY = os.environ.get("MPE_KEY", "")
WORK = os.environ.get("MPE_WORK", "/root/mpe/work")
GUARD_EVERY = int(os.environ.get("MPE_GUARD_EVERY", "25"))

SYSTEM = "You are an expert C# programmer."

PROMPT = """Complete the body of this C# method. The signature and the opening brace are already written.

{prompt}

Reply with the statements of the body only: no signature, no opening brace, no closing brace, no markdown fences, no explanation."""


def served_model():
    """The id the endpoint is actually serving, or None if it will not say."""
    req = urllib.request.Request(BASE + "/models", headers={"Authorization": "Bearer " + KEY})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
    ids = [m.get("id") for m in data.get("data") or []]
    ids += [m.get("name") for m in data.get("models") or []]
    return next((i for i in ids if i), None)


def require_model(model):
    """Abort instead of writing a file under a name that did not answer."""
    served = served_model()
    if served != model:
        raise SystemExit(
            "endpoint serves %r, not %r: switch the profile (superfast-switch use ...) "
            "or pass the served name. Nothing was written." % (served, model)
        )
    return served


def extract_body(text):
    """Keep the statements only: drop a repeated signature and the trailing brace."""
    code = strip_fences(text).strip()
    first = code.find("{")
    if first != -1:
        head = code[:first]
        if "(" in head and "static" in head:
            code = code[first + 1 :]
    code = code.rstrip()
    if code.endswith("}"):
        code = code[:-1].rstrip()
    return code + "\n"


def chat(model, prompt, timeout=900):
    body = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0,
            "stream": False,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEY},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
    msg = data["choices"][0]["message"]
    content = msg.get("content") or ""
    if not content.strip():
        content = msg.get("reasoning_content") or ""
    return content, data.get("usage", {})


def strip_fences(text):
    m = re.search(r"```[a-zA-Z0-9_+-]*\n(.*?)```", text, re.S)
    if m:
        return m.group(1)
    if text.lstrip().startswith("```"):
        body = text.lstrip()[3:]
        return body.split("\n", 1)[1] if "\n" in body else body
    return text


def ensure_project():
    os.makedirs(WORK, exist_ok=True)
    csproj = os.path.join(WORK, "mpe.csproj")
    if not os.path.exists(csproj):
        with open(csproj, "w", encoding="utf-8") as fh:
            fh.write(
                '<Project Sdk="Microsoft.NET.Sdk">\n'
                "  <PropertyGroup>\n"
                "    <OutputType>Exe</OutputType>\n"
                "    <TargetFramework>net8.0</TargetFramework>\n"
                "    <Nullable>disable</Nullable>\n"
                "    <ImplicitUsings>disable</ImplicitUsings>\n"
                "    <NoWarn>CS0168;CS0219;CS0414;CS0649;CS8632</NoWarn>\n"
                "    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>\n"
                "  </PropertyGroup>\n"
                "</Project>\n"
            )
    dotnet = os.path.expanduser("~/rcb/RepoClassBench/external/csharp/dotnet_dir/dotnet")
    return dotnet


def run_task(dotnet, source, timeout=300):
    path = os.path.join(WORK, "Program.cs")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(source)
    build = subprocess.run(
        [dotnet, "build", "-v", "q", "--nologo"],
        cwd=WORK,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if build.returncode != 0:
        return False, False, (build.stdout + build.stderr)[-400:]
    run = subprocess.run(
        [dotnet, "run", "--no-build"],
        cwd=WORK,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return True, run.returncode == 0, (run.stdout + run.stderr)[-400:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="the id /v1/models must report")
    ap.add_argument("--dataset", default="multipl_e_cs.jsonl", help="MultiPL-E humaneval-cs rows")
    ap.add_argument("--tasks", default="all")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    served = require_model(args.model)

    rows = [json.loads(line) for line in open(args.dataset, encoding="utf-8")]
    if args.tasks == "all":
        indices = list(range(len(rows)))
    else:
        indices = [int(x) for x in args.tasks.split(",") if x.strip()]
    if args.limit:
        indices = indices[: args.limit]

    done = set()
    if os.path.exists(args.out):
        for line in open(args.out, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    done.add(json.loads(line)["index"])
                except Exception:
                    pass
    indices = [i for i in indices if i not in done]
    print("SERVED", served, "PENDING", len(indices), "SKIPPED", len(done), flush=True)

    dotnet = ensure_project()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    for n, i in enumerate(indices, 1):
        if n > 1 and (n - 1) % GUARD_EVERY == 0:
            # The profile can be switched while a long run is in flight.
            require_model(args.model)
        row = rows[i]
        started = time.strftime("%Y-%m-%dT%H:%M:%S")
        t0 = time.time()
        rec = {"index": i, "name": row["name"], "model": args.model, "served": served,
               "started": started}
        try:
            completion, usage = chat(args.model, PROMPT.format(prompt=row["prompt"]))
            rec["completion_tokens"] = usage.get("completion_tokens")
            code = extract_body(completion)
            rec["gen_seconds"] = round(time.time() - t0, 1)
            rec["code_chars"] = len(code)
            source = row["prompt"] + code + "\n" + row["tests"]
            compiled, passed, tail = run_task(dotnet, source)
            rec["compiled"] = compiled
            rec["passed"] = bool(compiled and passed)
            rec["tail"] = tail if not rec["passed"] else ""
        except Exception as exc:  # noqa: BLE001
            rec["passed"] = False
            rec["compiled"] = False
            rec["error"] = "%s: %s" % (type(exc).__name__, exc)
        rec["seconds"] = round(time.time() - t0, 1)
        with open(args.out, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        print(
            "TASK", i, row["name"], "ok", rec["passed"], "compiled", rec.get("compiled"),
            rec["seconds"], "s", flush=True,
        )


if __name__ == "__main__":
    main()
