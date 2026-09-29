"""Run small streams on every fast engine and show which agree:
python3 gym/matrix.py 'b"..."' ... (TMUX_REF picks the tmux)."""
import os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import consensus
tmp = tempfile.mkdtemp()
eng = consensus.engines(tmp)
try:
    for lit in sys.argv[1:]:
        data = eval(lit)
        r = {e.name: e.render(data, tmp) for e in eng}
        groups = {}
        for k, v in r.items():
            key = next((g for g in groups if consensus.same(g, v)), v)
            groups.setdefault(key, []).append(k)
        print(repr(data)[:70])
        for v, names in groups.items():
            print(f'   {",".join(names):32s} joined={v[1]} cursor={v[2]}')
finally:
    for e in eng:
        getattr(e, 'close', lambda: None)()
