"""Runs in the pane under test: copies what the driver writes into a FIFO to
the pane (the terminal tmux emulates), and reads the pane's input so keys,
mouse reports and replies never back up. Each Enter it reads (CR, or kitty's
CSI 13 u press) is counted and reported as OSC 7 k<count>, which the driver
reads back as #{pane_path} to know tmux has delivered everything before it.

    python3 feeder.py FIFO
"""

import os
import re
import select
import sys
import tty

ENTER = re.compile(rb'\r|\033\[13(?:;\d+(?::1)?)?u')

fifo = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
tty.setraw(0)
pending = b''
enters = 0


def write_all(data):
    while data:
        n = os.write(1, data)
        data = data[n:]


while True:
    r, _, _ = select.select([fifo, 0], [], [])
    if fifo in r:
        data = os.read(fifo, 65536)
        if data:
            write_all(data)
    if 0 in r:
        data = os.read(0, 65536)
        if not data:
            sys.exit(0)
        pending += data
        end = 0
        found = 0
        for m in ENTER.finditer(pending):
            found += 1
            end = m.end()
        # Keep only what could be the start of a split CSI 13 u.
        pending = pending[end:][-16:]
        if found:
            enters += found
            write_all(b'\033]7;k%d\007' % enters)
