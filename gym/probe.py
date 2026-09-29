"""Compare one small stream on the model and on Ghostty: python3 gym/probe.py COLS ROWS 'python-bytes-literal' [...]"""
import sys, os, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vt
cols, rows = int(sys.argv[1]), int(sys.argv[2])
for lit in sys.argv[3:]:
    data = eval(lit)
    f = tempfile.mktemp()
    open(f, 'wb').write(data)
    out = subprocess.run([os.path.join(os.path.dirname(__file__), 'ghostty', 'gvt'), str(cols), str(rows), '1', f], capture_output=True).stdout.decode()
    t = vt.Term(cols, rows, vt.GHOSTTY); t.feed(data)
    g = out.split('@@rows\n')[1].split('@@joined')[0].rstrip('\n').split('\n')
    m = [t.row_text(i) for i in range(len(t.sb) + rows)] if False else [l for l, _ in t.lines()]
    while m and not m[-1]: m.pop()
    print(repr(data)[:70], ' ghostty cursor', out.split('@@cursor ')[1].strip(), ' model', t.state_of()['cursor'], t.pending)
    for i in range(max(len(g), len(m))):
        a = g[i] if i < len(g) else '-'; b = m[i] if i < len(m) else '-'
        print('   %s g|%s|  m|%s|' % (' ' if a == b else 'X', a, b))
