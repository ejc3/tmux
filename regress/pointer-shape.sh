#!/bin/sh

# The mouse pointer shape (OSC 22), as kitty: a pane sets, pushes (a list),
# pops and resets its shape and asks for it, with a stack of at least 16 for
# each of the main and alternate screens, emptied by RIS; the terminal (with
# the pointer feature)
# is given the active pane's shape, once, forwarding or not.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

# Whether the answer has come: it ends with ST, ^[\ once through cat -v.
replied() {
	case "$(cat $DIR/r 2>/dev/null)" in
	*'^[\') return 0 ;;
	esac
	return 1
}

# Answers: the program sends $1 then a query, and keeps the reply.
answer() {
	rm -f $DIR/r
	$INNER new -d -x 40 -y 5 "stty raw -echo; \
	    printf '$1\033]22;?$2\033\\\\'; exec cat -v >$DIR/r" || exit 1
	wait_for replied 400 || { echo "$1 ?$2: no answer"; exit 1; }
	$INNER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file'" 400
	out=$(cat $DIR/r)
	[ "$out" = "^[]22;$3^[\\" ] || { echo "$1 ?$2: '$out', want '$3'"; exit 1; }
}
answer '' __current__ 0
answer '\033]22;=crosshair\033\\\\' __current__ crosshair
answer '\033]22;wait\033\\\\' __current__ wait
answer '\033]22;wait\033\\\\\033]22;\033\\\\' __current__ 0
answer '\033]22;>text\033\\\\' __current__ text
answer '\033]22;=wait\033\\\\\033]22;>text\033\\\\\033]22;<\033\\\\' __current__ wait
answer '' pointer,nonsense,left_ptr 1,0,0
answer '\033]22;>crosshair,wait\033\\\\\033]22;<\033\\\\' __current__ crosshair
# Pushing 15 onto one leaves 16, all kept.
PUSH='\033]22;>text\033\\\\'
POP='\033]22;<\033\\\\'
PUSH5=$PUSH$PUSH$PUSH$PUSH$PUSH
POP5=$POP$POP$POP$POP$POP
answer "\\033]22;=wait\\033\\\\\\\\$PUSH5$PUSH5$PUSH5$POP5$POP5$POP5" __current__ wait
answer '\033]22;crosshair\033\\\\\033[?1049h' __current__ 0
answer '\033]22;crosshair\033\\\\\033[?1049h\033]22;wait\033\\\\\033[?1049l' __current__ crosshair
answer '\033]22;crosshair\033\\\\\033c' __current__ 0

# How many OSC 22 the terminal has been given.
shapes() {
	grep -ao "$(printf '\033')]22;[a-z]*" $DIR/out 2>/dev/null | wc -l
}

# The terminal: pane 0 sets crosshair; pane 1 sets nothing. Selecting pane 1
# resets the shape, selecting pane 0 sets it again, and the client leaving
# (the server is killed) gives the terminal its own shape back.
cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033]22;crosshair\033\\'
touch "$1/done"
exec sleep 100000
EOS
for mode in on off; do
	rm -f $DIR/go $DIR/done $DIR/out
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features ',xterm*:pointer' || exit 1
	$INNER show -s forward-output >/dev/null 2>&1 &&
	    { $INNER set -s forward-output $mode || exit 1; }
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
	wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
	    exit 1
	$OUTER pipep -O -t tmux "cat >$DIR/out" || exit 1
	touch $DIR/go
	# Each step gives the terminal one more OSC 22.
	wait_for "[ \$(shapes) -ge 1 ]" 400 || { echo "no shape set"; exit 1; }
	$INNER splitw -d "exec sleep 100000" || exit 1
	$INNER selectp -t :.1 || exit 1
	wait_for "[ \$(shapes) -ge 2 ]" 400 || { echo "no reset"; exit 1; }
	$INNER selectp -t :.0 || exit 1
	wait_for "[ \$(shapes) -ge 3 ]" 400 || { echo "no shape again"; exit 1; }
	# Suspending resets it and resuming sets it again. (The client's
	# SIGTSTP is discarded, its process group being orphaned; SIGCONT
	# wakes it as fg would.)
	pid=$($INNER lsc -F '#{client_pid}')
	$INNER suspendc || exit 1
	wait_for "[ \$(shapes) -ge 4 ]" 400 || { echo "no reset on suspend"; exit 1; }
	kill -CONT $pid || exit 1
	wait_for "[ \$(shapes) -ge 5 ]" 400 || { echo "no shape on resume"; exit 1; }
	$INNER kill-server 2>/dev/null
	wait_for "[ \$(shapes) -ge 6 ]" 400 || { echo "no reset on leaving"; exit 1; }
	$OUTER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file' && $OUTER ls 2>&1 | grep -qE 'no server running|No such file'" 100
	got=$(grep -ao "$(printf '\033')]22;[a-z]*" $DIR/out | cat -v | tr '\n' ' ')
	[ "$got" = "^[]22;crosshair ^[]22; ^[]22;crosshair ^[]22; ^[]22;crosshair ^[]22; " ] || {
		echo "forward-output $mode: terminal given '$got'"
		exit 1
	}
done

# A terminal that is found to have the feature after attaching (here when it
# answers XTVERSION as kitty) is given the shape set before then. A pty stands
# in for the terminal: it answers nothing but what is written to $DIR/in.
cat >$DIR/term.py <<'EOS'
import os, pty, select, struct, sys, fcntl, termios
out = open(sys.argv[1], "ab", 0)
fifo = os.open(sys.argv[2], os.O_RDWR)
pid, fd = pty.fork()
if pid == 0:
	fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
	os.execvp(sys.argv[3], sys.argv[3:])
while True:
	r = select.select([fd, fifo], [], [])[0]
	if fifo in r:
		os.write(fd, os.read(fifo, 4096))
	if fd in r:
		try:
			data = os.read(fd, 4096)
		except OSError:
			break
		if not data:
			break
		out.write(data)
os.waitpid(pid, 0)
EOS
rm -f $DIR/out
mkfifo $DIR/in || exit 1
$INNER new -d -x 80 -y 24 \
    "printf '\033]22;crosshair\033\\\\\033]7;done\007'; exec sleep 100000" \; \
    set -g status off || exit 1
wait_for "[ \"\$($INNER display -p '#{pane_path}')\" = done ]" 400 ||
    { echo "shape not set"; exit 1; }
TERM=xterm-256color python3 $DIR/term.py $DIR/out $DIR/in \
    sh -c "unset TMUX; exec $INNER attach" &
wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 400 || { echo "no client"; exit 1; }
$INNER display -p x >/dev/null	# a server loop with the client attached
printf '\033P>|kitty(0.40.0)\033\\' >$DIR/in
wait_for "$INNER lsc -F '#{client_termfeatures}' | grep -q pointer" 400 ||
    { echo "pointer feature not learned"; exit 1; }
wait_for "grep -aq \"\$(printf '\033')]22;crosshair\" $DIR/out" 400 ||
    { echo "shape not given once the feature was learned"; exit 1; }
$INNER kill-server 2>/dev/null
wait
exit 0
