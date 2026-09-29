"""vte: feed a byte stream to VTE (GNOME Terminal's engine) and print what it
holds, in gvt's format. VTE gives its text with soft-wrapped lines joined, so
there is no "@@rows" section, only "@@joined" and "@@cursor".

    xvfb-run -a python3 gym/refs/vte.py COLS ROWS STREAM [EVENTS]
"""

import sys

import gi
gi.require_version('Vte', '2.91')
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Vte  # noqa: E402


def pump():
    """Let VTE's main loop run until it has consumed what it was fed (it
    parses input from an idle handler, not in feed())."""
    import time
    quiet = 0
    while quiet < 20:
        busy = False
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
            busy = True
        quiet = 0 if busy else quiet + 1
        time.sleep(0.005)


def main():
    cols, rows = int(sys.argv[1]), int(sys.argv[2])
    data = open(sys.argv[3], 'rb').read()
    events = open(sys.argv[4]).read().split('\n') if len(sys.argv) > 4 else []
    win = Gtk.Window()
    t = Vte.Terminal()
    t.set_scrollback_lines(-1)
    t.set_size(cols, rows)
    win.add(t)
    win.show_all()
    pump()
    at = 0
    for line in events:
        p = line.split()
        if len(p) < 2:
            continue
        off = min(int(p[0]), len(data))
        if off > at:
            t.feed(data[at:off])
            pump()
            at = off
        if p[1] == 'resize':
            cols, rows = int(p[2]), int(p[3])
            t.set_size(cols, rows)
        elif p[1] == 'hidden':
            t.set_size(cols, rows + int(p[2]))
            pump()
            t.set_size(cols, rows)
        pump()
    if at < len(data):
        t.feed(data[at:])
    pump()
    adj = t.get_vadjustment()
    lower, upper = int(adj.get_lower()), int(adj.get_upper())
    text = t.get_text_range_format(Vte.Format.TEXT, lower, 0, upper - 1, cols - 1)[0] or ''
    x, y = t.get_cursor_position()
    sys.stdout.write('@@joined\n' + text.rstrip('\n') + '\n')
    sys.stdout.write(f'@@cursor {x} {y - (upper - rows)} 0 0\n')


if __name__ == '__main__':
    main()
