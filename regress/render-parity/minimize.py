#!/usr/bin/env python3
"""Shrink a differing fuzz case to the fewest operations that still differ.

    python3 minimize.py SEED [TMUX]   -> prints the operations, writes min-SEED/

Runs ../render-parity.sh on candidate cases in a scratch directory (ddmin over
the generator's operations; each candidate is split into chunks as the
generator does).
"""
import os, random, subprocess, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate

HERE = os.path.dirname(os.path.abspath(__file__))
seed = int(sys.argv[1])
tmux = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "..", "tmux")
work = tempfile.mkdtemp()

orig_write = generate.write

def ops_of(seed):
    generate.fuzz(seed)
    return list(generate.LAST_OPS)

def differs(ops):
    d = os.path.join(work, "c")
    chunks = [ops[i:i + max(1, len(ops) // 5)] for i in range(0, len(ops), max(1, len(ops) // 5))]
    generate.HERE = work
    orig_write("c", ["".join(c) for c in chunks], None)
    env = dict((k, v) for k, v in os.environ.items() if not k.startswith("TMUX"))
    env.update(TEST_TMUX=os.path.abspath(tmux), RENDER_PARITY_DIR=work, RENDER_PARITY_CASES="c")
    return subprocess.run(["sh", os.path.join(HERE, "..", "render-parity.sh")], cwd=os.path.join(HERE, ".."),
                          env=env, capture_output=True).returncode != 0

ops = ops_of(seed)
assert differs(ops), "case does not differ"
n = 2
while len(ops) >= 2:
    size = max(1, len(ops) // n); reduced = False
    for i in range(0, len(ops), size):
        cand = ops[:i] + ops[i + size:]
        if cand and differs(cand):
            ops, n, reduced = cand, max(n - 1, 2), True
            break
    if not reduced:
        if n >= len(ops):
            break
        n = min(len(ops), n * 2)
generate.HERE = HERE
orig_write("min-%d" % seed, ["".join(ops)], None)
for o in ops:
    print(repr(o))
