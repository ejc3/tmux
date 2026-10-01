#!/usr/bin/env python3
"""Which changed lines no test reached: the blind-spot map.

Reads the gcov JSON (gcov --json-format) of a --coverage tmux build after
the tests have run, and the lines a range of commits added, and prints the
added lines that are executable but never ran, grouped by file and function.

    python3 gym/coverage_map.py BUILD_DIR BASE COMMIT [--json OUT]

BUILD_DIR is the tmux checkout the coverage build is in (its .gcda files
hold the counts); BASE..COMMIT is the range whose added lines count.
"""

import argparse
import json
import os
import re
import subprocess
import sys


def added_lines(repo, base, commit):
    """{file: set(line numbers in COMMIT)} for lines BASE..COMMIT added."""
    diff = subprocess.run(["git", "-C", repo, "diff", "-U0", base, commit,
                           "--", "*.c"], stdout=subprocess.PIPE,
                          check=True).stdout.decode(errors="replace")
    out = {}
    name = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            name = line[6:] if line.startswith("+++ b/") else None
        m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
        if m and name:
            start, n = int(m.group(1)), int(m.group(2) or 1)
            out.setdefault(name, set()).update(range(start, start + n))
    return out


def coverage(build):
    """{file: {line: (count, function)}} from gcov's JSON."""
    gcda = [f for f in os.listdir(build) if f.endswith(".gcda")]
    gcda += ["compat/" + f for f in os.listdir(os.path.join(build, "compat"))
             if f.endswith(".gcda")] if os.path.isdir(
                 os.path.join(build, "compat")) else []
    subprocess.run(["gcov", "--json-format", "--stdout"] + gcda, cwd=build,
                   stdout=open(os.path.join(build, "gcov.jsonl"), "w"),
                   stderr=subprocess.DEVNULL)
    out = {}
    with open(os.path.join(build, "gcov.jsonl")) as f:
        for doc in f:
            doc = doc.strip()
            if not doc:
                continue
            data = json.loads(doc)
            for fi in data.get("files", []):
                lines = out.setdefault(os.path.normpath(fi["file"]), {})
                for ln in fi.get("lines", []):
                    n = ln["line_number"]
                    count, fn = lines.get(n, (0, ""))
                    lines[n] = (count + ln["count"],
                                ln.get("function_name", fn) or fn)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build")
    ap.add_argument("base")
    ap.add_argument("commit")
    ap.add_argument("--json")
    a = ap.parse_args()
    added = added_lines(a.build, a.base, a.commit)
    cov = coverage(a.build)
    total = run = 0
    report = {}
    for name in sorted(added):
        lines = cov.get(name, {})
        for n in sorted(added[name]):
            if n not in lines:
                continue
            total += 1
            count, fn = lines[n]
            if count:
                run += 1
                continue
            report.setdefault(name, {}).setdefault(fn or "?", []).append(n)
    print("changed executable lines: %d, run: %d (%.1f%%), never run: %d" %
          (total, run, 100.0 * run / max(total, 1), total - run))
    for name, fns in report.items():
        print("\n%s" % name)
        for fn, ns in sorted(fns.items(), key=lambda kv: -len(kv[1])):
            spans = []
            for n in ns:
                if spans and n == spans[-1][1] + 1:
                    spans[-1][1] = n
                else:
                    spans.append([n, n])
            text = ", ".join("%d" % s if s == e else "%d-%d" % (s, e)
                             for s, e in spans)
            print("  %-36s %3d  %s" % (fn, len(ns), text))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"total": total, "run": run, "never": report}, f,
                      indent=1)


if __name__ == "__main__":
    sys.exit(main())
