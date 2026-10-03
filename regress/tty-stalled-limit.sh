#!/bin/sh

# A terminal that stops taking output (a frozen ssh connection, flow control
# left on) while a pane keeps writing: the server must stop queueing output
# for it and start discarding, as it does for a terminal that is only slow.
# Whether a terminal is behind was only checked after it took something, so
# for one taking nothing the queue grew without limit, by megabytes a second.
#
# The stalled terminal is a pty whose other end is read until the client has
# attached and then left alone.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

DIR=$(mktemp -d)
PY=
cleanup() {
	[ -n "$PY" ] && kill $PY 2>/dev/null
	$TMUX kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

$TMUX new -d -x 80 -y 24 -s main \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; exec yes flood-flood-flood" ||
    exit 1

# Attach on a pty, read it until told to stop, then only hold it open.
python3 - $DIR/stop $TMUX attach -t main <<'EOF' &
import fcntl, os, pty, select, struct, sys, termios, time
stop = sys.argv[1]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
if os.fork() == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.environ['TERM'] = 'xterm'
    os.execvp(sys.argv[2], sys.argv[2:])
os.close(slave)
while not os.path.exists(stop):
    if select.select([master], [], [], 0.05)[0]:
        os.read(master, 65536)
time.sleep(100000)
EOF
PY=$!

wait_for "[ \"\$($TMUX lsc -F '#{client_discarded}' 2>/dev/null)\" = 0 ]" 400 ||
    { echo "client did not attach"; exit 1; }

# The terminal stops reading, then the pane floods.
touch $DIR/stop
sleep 0.2
touch $DIR/go

wait_for "[ \"\$($TMUX lsc -F '#{client_discarded}')\" != 0 ]" 200 || {
	echo "nothing discarded for a stalled terminal:" \
	    "$($TMUX lsc -F '#{client_written} written')"
	exit 1
}
exit 0
