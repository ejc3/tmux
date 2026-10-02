"""Resource gym: does the tmux server survive running short of descriptors,
disk and time, and give back what it took?

    python3 gym/resource.py --tmux BIN [--asan] [--only NAME,...]

Each check runs one server (gym/memory.py's Server, Terminal and feeder) and
requires: the server still answers, no AddressSanitizer or UBSan report
(--asan), and afterwards as many descriptors open in the server as before.

fds        The server limited to 64 descriptors: clients attach, panes are
           made, pipe-pane and kitty graphics files are opened, past the
           limit. Commands may fail; the server may not.
disk       save-buffer and pipe-pane writing to a full filesystem (a 64 KB
           tmpfs, mounted with sudo; skipped with a message if it cannot be).
clients    200 control-mode clients attached at once, then gone.
firehose   A pane writing as fast as it can while four terminals read at
           different speeds (one stalls): the server answers commands within
           a second throughout, and its heap stays bounded.
"""

import argparse
import os
import re
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import memory as m  # noqa: E402

MB = 1024 * 1024


def fds(pid):
    return len(os.listdir('/proc/%d/fd' % pid))


def answers(g, within=5):
    start = time.time()
    try:
        g.server.cmd('display', '-p', 'x', timeout=within)
    except (m.Fail, subprocess.TimeoutExpired):
        return None
    return time.time() - start


def settle_fds(g, want, what):
    # The server closes descriptors as clients and panes go; give it until
    # the count is back.
    try:
        m.wait(lambda: fds(g.server.pid) <= want, what, timeout=20)
    except m.Fail:
        raise m.Fail('%s: %d descriptors open, %d before' %
                     (what, fds(g.server.pid), want))


def try_cmd(g, *args):
    try:
        return g.server.cmd(*args, check=False, timeout=3)
    except subprocess.TimeoutExpired:
        return None


def check_fds(g):
    """Fill the descriptors the server may have, raise the limit from
    outside, and require it to recover and give them all back."""
    pid = g.server.pid
    before = fds(pid)
    path = m.tmpimage(g.tmp, os.urandom(3 * 4 * 4), 'fd')
    g.pane(m.gfx(b'a=t,f=24,s=4,v=4,t=f,i=1,q=2', m.b64(path.encode())))
    # Only the soft limit: lowering the hard one cannot be undone.
    soft, hard = subprocess.check_output(
        ['prlimit', '--pid', str(pid), '--nofile', '--output=SOFT,HARD',
         '--noheadings']).split()
    subprocess.run(['prlimit', '--pid', str(pid),
                    '--nofile=64:%s' % hard.decode()], check=True)
    panes = []
    for n in range(60):
        p = try_cmd(g, 'split-window', '-d', '-P', '-F', '#{pane_id}',
                    'exec sleep 1000')
        if p is None:
            break              # out of descriptors: commands wait
        p = p.strip()
        if p.startswith('%'):
            panes.append(p)
            try_cmd(g, 'pipe-pane', '-t', p, 'cat >/dev/null')
            try_cmd(g, 'select-layout', 'tiled')
    full = fds(pid)
    # A graphics file read and a new client at the limit.
    os.write(g.wfd, m.gfx(b'a=t,f=24,s=4,v=4,t=f,i=2,q=2',
                          m.b64(path.encode())))
    subprocess.run(['prlimit', '--pid', str(pid), '--nofile=%s:%s' % (
        soft.decode(), hard.decode())], check=True)
    took = answers(g, within=15)
    if took is None:
        raise m.Fail('the server did not recover after the limit was raised')
    for p in panes:
        g.server.cmd('kill-pane', '-t', p, check=False)
    g.pane(m.gfx(b'a=d,d=I,i=1') + m.gfx(b'a=d,d=I,i=2'))
    settle_fds(g, before, 'descriptors after the limit')
    return ('%d panes to the limit (%d descriptors); answered %.1f s after '
            'it was raised; all given back' % (len(panes), full, took))


def check_disk(g):
    mnt = tempfile.mkdtemp(prefix='gymres-full-')
    r = subprocess.run(['sudo', '-n', 'mount', '-t', 'tmpfs', '-o',
                        'size=64k,mode=1777', 'tmpfs', mnt],
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        os.rmdir(mnt)
        return 'skipped: cannot mount a tmpfs (%s)' % r.stderr.decode().strip()
    try:
        before = fds(g.server.pid)
        with open(os.path.join(mnt, 'fill'), 'wb') as f:
            try:
                f.write(b'x' * 128 * 1024)
            except OSError:
                pass
        big = os.path.join(g.tmp, 'big')
        with open(big, 'wb') as f:
            f.write(b'x' * 100000)
        g.server.cmd('load-buffer', big)
        for n in range(20):
            g.server.cmd('save-buffer', os.path.join(mnt, 'buf%d' % n),
                         check=False)
        g.server.cmd('pipe-pane', '-o', 'cat >%s/pipe' % mnt)
        g.pane(b'y' * 200000)
        g.server.cmd('pipe-pane', check=False)
        g.server.cmd('capture-pane', '-b', 'cap', check=False)
        g.server.cmd('save-buffer', '-b', 'cap', os.path.join(mnt, 'cap'),
                     check=False)
        if answers(g) is None:
            raise m.Fail('the server stopped answering with the disk full')
        settle_fds(g, before, 'descriptors after a full disk')
        return 'save-buffer and pipe-pane to a full filesystem'
    finally:
        subprocess.run(['sudo', '-n', 'umount', mnt])
        os.rmdir(mnt)


def check_clients(g, n=200):
    before = fds(g.server.pid)
    procs = []
    for i in range(n):
        procs.append(subprocess.Popen(
            [g.server.tmux, '-L' + g.server.label, '-f' + g.server.conf,
             '-C', 'attach'], env=g.server.env, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    m.wait(lambda: len(g.server.cmd('list-clients').splitlines()) >= n + 1,
           '%d clients' % n, timeout=60)
    g.pane(b'to all of them\r\n' * 50)
    if answers(g) is None:
        raise m.Fail('the server stopped answering with %d clients' % n)
    for p in procs:
        p.stdin.close()
    for p in procs:
        p.wait(timeout=60)
    m.wait(lambda: len(g.server.cmd('list-clients').splitlines()) == 1,
           'clients to go', timeout=60)
    settle_fds(g, before, 'descriptors after %d clients' % n)
    return '%d clients attached and gone' % n


def check_firehose(g, seconds=20, bound=64 * MB):
    g.term.close()
    g.terms.remove(g.term)
    rates = [None, 2 * MB, 64 * 1024, None]
    terms = [m.Terminal(g.server, rate=r) for r in rates]
    g.terms.extend(terms)
    g.term = terms[0]
    stall = terms[3]
    pane = g.server.cmd('split-window', '-d', '-P', '-F', '#{pane_id}',
                        'exec yes "firehose firehose firehose"').strip()
    worst = 0
    peak = 0
    heap = g.server.heap if g.server.env.get('LD_PRELOAD') else None
    end = time.time() + seconds
    while time.time() < end:
        stall.rate = 1 if int(time.time()) % 4 < 2 else None
        took = answers(g, within=10)
        if took is None:
            raise m.Fail('the server stopped answering under the firehose')
        worst = max(worst, took)
        if heap is not None:
            peak = max(peak, heap()[2])
        time.sleep(0.2)
    g.server.cmd('kill-pane', '-t', pane)
    if worst > 1:
        raise m.Fail('a command took %.1f s under the firehose' % worst)
    if peak > bound:
        raise m.Fail('peak heap %d MB under the firehose' % (peak // MB))
    return 'commands answered within %.2f s; peak heap %s' % (
        worst, '%d MB' % (peak // MB) if heap else 'not measured')


CHECKS = [('fds', check_fds), ('disk', check_disk),
          ('clients', check_clients), ('firehose', check_firehose)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tmux', required=True)
    ap.add_argument('--asan', action='store_true',
                    help='the binary is an ASan build: check its logs')
    ap.add_argument('--only', default='')
    ap.add_argument('--keep')
    args = ap.parse_args()
    tmux = os.path.abspath(args.tmux)
    only = [x for x in args.only.split(',') if x]
    work = tempfile.mkdtemp(prefix='gymres-')
    heapcount = None if args.asan else m.build_heapcount(work)
    failed = False
    print('| check | mode | result |')
    print('|---|---|---|')
    for name, fn in CHECKS:
        if only and name not in only:
            continue
        for mode in ('forward', 'translate'):
            g = m.Gym(tmux, mode, heapcount, args.asan, args.keep)
            pid = g.server.pid
            try:
                result = fn(g)
                if not g.server.alive():
                    result, bad = 'SERVER DIED', True
                else:
                    bad = False
            except m.Fail as e:
                result, bad = 'FAIL %s' % e, True
            finally:
                g.close()
            if args.asan:
                reports = m.asan_reports(g.tmp, pid)
                if reports:
                    first = reports[0][1]
                    kind = re.search(r'ERROR: (\w+Sanitizer: [^\n]*)|'
                                     r'runtime error: [^\n]*', first)
                    result = 'REPORT %s (%s)' % (
                        kind.group(0) if kind else 'see log',
                        os.path.join(g.tmp, reports[0][0]))
                    bad = True
            failed |= bad
            print('| %s | %s | %s |' % (name, mode, result), flush=True)
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
