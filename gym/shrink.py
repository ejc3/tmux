"""Shrink a stream on which the model and a reference disagree to a small one
that still disagrees (delta debugging over whole escape sequences and
characters), so the cause can be read off.

    python3 gym/shrink.py [--ghostty] NAME       (a validate.py stream name)
"""

import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate  # noqa: E402
import fuzz      # noqa: E402
import vt        # noqa: E402

TOKEN = re.compile(rb'\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|'
                   rb'\x1b[()*+#%].|\x1b.|[\xc0-\xf7][\x80-\xbf]*|.', re.S)


def tokens(data):
    return TOKEN.findall(data)


def ddmin(items, fails):
    n = 2
    while len(items) >= 2:
        chunk = max(1, len(items) // n)
        subsets = [items[i:i + chunk] for i in range(0, len(items), chunk)]
        reduced = False
        for i in range(len(subsets)):
            rest = [t for j, s in enumerate(subsets) if j != i for t in s]
            if fails(rest):
                items = rest
                n = max(n - 1, 2)
                reduced = True
                break
        if not reduced:
            if n >= len(items):
                break
            n = min(len(items), n * 2)
    return items


def main():
    args = sys.argv[1:]
    ghostty = '--ghostty' in args
    name = [a for a in args if not a.startswith('--')][0]
    tmp = tempfile.mkdtemp(prefix='gym-shrink.')
    if ghostty:
        ref = validate.GhosttyRef(tmp)
        validate.PROFILE = vt.GHOSTTY
    else:
        ref = validate.Ref(os.environ.get('TMUX_REF', 'tmux'), tmp)
        validate.PROFILE = vt.TMUXPANE
    try:
        if name.startswith('vtfuzz-'):
            data = fuzz.stream(int(name.split('-')[1]))
        else:
            data = dict(validate.parity_cases(tmp))[name]
        fails = lambda toks: bool(validate.compare(name, b''.join(toks), ref))
        toks = tokens(data)
        assert fails(toks), 'stream does not fail'
        small = ddmin(toks, fails)
        out = b''.join(small)
        print(f'{len(data)} bytes -> {len(out)} bytes:')
        print(repr(out))
        validate.show(name, validate.compare(name, out, ref))
    finally:
        ref.close()


if __name__ == '__main__':
    main()
