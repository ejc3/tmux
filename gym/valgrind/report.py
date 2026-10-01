"""Summarise valgrind logs from gym/valgrind/run-regress.sh or memory.py.

    python3 gym/valgrind/report.py DIR...

Reads every vg.PID file below each DIR, splits it into errors (invalid
reads and writes, uses of uninitialised values, leaks definitely or
indirectly lost, and any other memcheck error), and prints each distinct
error once - keyed by its kind and its first frames in tmux - with the
scripts or scenarios (the directory the log was in) that produced it.
"""

import collections
import os
import re
import sys

HEAD = re.compile(r'^==(\d+)== (\S.*)$')
FRAME = re.compile(r'^==\d+==\s+(?:at|by) 0x[0-9A-F]+: (\S+) \((.*)\)$')


def errors(path):
    """Yield (kind, frames) for each error in one log."""
    kind = None
    frames = []
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        f = FRAME.match(line)
        if f:
            if kind is not None:
                frames.append((f.group(1), f.group(2)))
            continue
        h = HEAD.match(line)
        if h:
            text = h.group(2)
            if text.startswith(('Address ', 'Uninitialised value was',
                                'Block was')):
                # Detail of the error being read: keep its frames apart.
                frames.append(('--', text))
                continue
            if kind is not None and frames:
                yield kind, frames
            kind, frames = text, []
        elif re.match(r'^==\d+==\s*$', line) and kind is not None:
            continue
    if kind is not None and frames:
        yield kind, frames


def key(kind, frames):
    kind = re.sub(r'\d[\d,]* (bytes|blocks)', 'N \\1', kind)
    kind = re.sub(r'loss record [\d,]+ of [\d,]+', 'loss record', kind)
    ours = [f for f in frames if f[0] != '--' and '.c:' in f[1]][:4]
    return kind, tuple(f[0] for f in ours)


def main():
    seen = collections.OrderedDict()
    for top in sys.argv[1:]:
        for dirpath, _, files in os.walk(top):
            for name in files:
                if not name.startswith('vg.'):
                    continue
                path = os.path.join(dirpath, name)
                if os.path.getsize(path) == 0:
                    continue
                for kind, frames in errors(path):
                    k = key(kind, frames)
                    if k not in seen:
                        seen[k] = (kind, frames, set())
                    seen[k][2].add(os.path.basename(dirpath))
    if not seen:
        print('no valgrind errors')
        return 0
    for (kind, _), (full, frames, where) in seen.items():
        print('== %s' % full)
        for fn, loc in frames[:14]:
            print('   %s %s' % (fn, loc))
        print('   in: %s' % ', '.join(sorted(where)[:8])
              + (' (+%d more)' % (len(where) - 8) if len(where) > 8 else ''))
        print()
    print('%d distinct errors' % len(seen))
    return 1


if __name__ == '__main__':
    sys.exit(main())
