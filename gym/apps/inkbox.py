"""Draws like Claude Code (ink): conversation lines, then an input box that is
redrawn in place relative to the cursor - up to its first row, erase each
row, write it again - inside synchronized output, as text is typed and when
the terminal is resized. Nothing is ever drawn at an absolute row."""
import signal
from common import App

a = App()
TYPED = ['', 'we', 'we are going', 'we are going to fix it']
state = {'text': '', 'drawn': 0}


def box(cols):
    return ['─' * cols, '❯ ' + state['text'], '─' * cols, '  ⏵⏵ bypass permissions on']


def draw():
    cols, _ = a.size()
    out = '\033[?2026h'
    if state['drawn']:
        out += '\r' + (f'\033[{state["drawn"] - 1}A' if state['drawn'] > 1 else '')
    rows = box(cols)
    out += '\r\n'.join('\033[2K' + r for r in rows)
    out += '\033[?2026l'
    state['drawn'] = len(rows)
    a.w(out)


signal.signal(signal.SIGWINCH, lambda *_: draw())
for i in range(12):
    a.w(f'● line {i} of the conversation\r\n')
a.w('\r\n')
draw()
for t in TYPED[1:]:
    a.step()
    state['text'] = t
    draw()
a.step()
