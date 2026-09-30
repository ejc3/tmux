"""Random terminal output streams, the same for a given seed on any machine.

Each stream mixes text (ASCII, wide, combining), rows that exactly fill the
width, cursor movement absolute and relative, erases, line and character
insert/delete, scrolling and scroll regions, tabs, autowrap off and on, cursor
save/restore, the alternate screen and hyperlinks.
"""

import random

WIDE = ['日', '本', '語', '界', '🙂', '🚀']
COMBINING = ['é', 'ä', 'ñ']
WORDS = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta']


def stream(seed, cols=80, rows=24, n=None):
    r = random.Random(seed)
    out = []
    n = n or r.randint(20, 80)
    alt = False
    for _ in range(n):
        k = r.random()
        if k < 0.30:
            w = ' '.join(r.choice(WORDS) for _ in range(r.randint(1, 30)))
            out.append(w)
        elif k < 0.36:
            out.append(r.choice('abcdefgh') * cols)          # exactly full
        elif k < 0.40:
            out.append(''.join(r.choice(WIDE) for _ in range(r.randint(1, 45))))
        elif k < 0.42:
            out.append(''.join(r.choice(COMBINING) for _ in range(r.randint(1, 10))))
        elif k < 0.52:
            out.append('\r\n' * r.randint(1, 5))
        elif k < 0.60:
            out.append(f'\033[{r.randint(1, rows)};{r.randint(1, cols)}H')
        elif k < 0.66:
            out.append(f'\033[{r.randint(1, 6)}{r.choice("ABCD")}')
        elif k < 0.70:
            out.append(r.choice(['\033[K', '\033[1K', '\033[2K']))
        elif k < 0.73:
            out.append(r.choice(['\033[J', '\033[1J', '\033[2J']))
        elif k < 0.76:
            out.append(f'\033[{r.randint(1, 4)}{r.choice("LM@PX")}')
        elif k < 0.78:
            out.append(f'\033[{r.randint(1, 4)}{r.choice("ST")}')
        elif k < 0.81:
            t = r.randint(1, rows - 2)
            b = r.randint(t + 1, rows)
            out.append(f'\033[{t};{b}r')
        elif k < 0.83:
            out.append('\033[r')
        elif k < 0.85:
            out.append('\t' * r.randint(1, 3))
        elif k < 0.86:
            out.append('\b' * r.randint(1, 3))
        elif k < 0.87:
            out.append('\033[?7l' if r.random() < 0.5 else '\033[?7h')
        elif k < 0.89:
            out.append(r.choice(['\0337', '\0338', '\033[s', '\033[u']))
        elif k < 0.90:
            # Alternate screens and the saved cursor, including resets
            # outside the alternate screen.
            m = r.choice(['1049', '1049', '1047', '47', '1048'])
            on = r.random() < 0.5
            out.append(f'\033[?{m}{"h" if on else "l"}')
            if m != '1048':
                alt = on
        elif k < 0.92:
            out.append(r.choice(['\033D', '\033M', '\033E']))
        elif k < 0.94:
            out.append(f'\033[{r.randint(1, cols)}G')
        elif k < 0.95:
            out.append(f'\033[{r.randint(1, rows)}d')
        elif k < 0.97:
            out.append(f'\033]8;;https://example.com/{r.randint(0, 99)}\033\\'
                       + r.choice(WORDS) + '\033]8;;\033\\')
        else:
            out.append('\r')
    if alt:
        out.append('\033[?1049l')
    out.append('\033[r\033[?7h')
    return ''.join(out).encode()
