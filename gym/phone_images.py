"""Phone scenario images: gym/run.py scenarios on the Prompt profile, run
directly, through upstream tmux and through tmux with the fixes, last
screenful plus a few rows of scrollback, aligned at the bottom.
    python3 gym/phone_images.py OUTDIR UPSTREAM_TMUX FIXED_TMUX"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence  # noqa: E402
import run       # noqa: E402
import vt        # noqa: E402

out, up, br = sys.argv[1:4]
for name in ('keyboard-shift', 'full-rows'):
    cols, rows, b, t_up, ev_up, _ = run.run(name, up)
    _, _, _, t_br, ev_br, _ = run.run(name, br)

    def lines(t):
        return [l for l, _ in t.lines()]
    panels = []
    if name == 'full-rows':
        panels.append(('what the program draws (xterm)',
                       lines(run.replay(b, ev_up['bare'], cols, rows, vt.XTERM))))
    panels += [('run directly, Prompt', lines(run.replay(b, ev_up['bare'], cols, rows, vt.PROMPT))),
               ('upstream tmux, Prompt', lines(run.replay(t_up, ev_up['tmux'], cols, rows, vt.PROMPT))),
               ('fixed tmux, Prompt', lines(run.replay(t_br, ev_br['tmux'], cols, rows, vt.PROMPT)))]
    keep = rows + 4
    panels = [(t, ([''] * keep + p)[-keep:]) for t, p in panels]
    evidence.compare(panels, cols, context=2, max_rows=keep).save(
        os.path.join(out, f'phone-{name}.png'))
    print(name)
