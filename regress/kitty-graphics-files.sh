#!/bin/sh

# The kitty graphics protocol with images in files and shared memory, which
# tmux reads: only regular files, at most as much data as tmux keeps, a
# temporary file deleted only in a temporary directory, part of shared memory
# with O and S. An outer tmux stands in for the terminal (the inner tmux is
# told it has the protocol) and records what it is sent.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$"
DIR=$(mktemp -d)
HERE=$(pwd)/kgfx-tty-graphics-protocol-$$
SHM=/kgfx-test-$$
trap '$OUTER kill-server 2>/dev/null; timeout -s KILL 5 $INNER kill-server 2>/dev/null || pkill -9 -f -- "-LtestB$$"; rm -rf $DIR $HERE /dev/shm$SHM' 0 1 15

exit_status=0
fail() {
	echo "FAIL: $*"
	exit_status=1
}

# Wait until $1 prints $2. The inner tmux must answer within 5 seconds.
wait_is() {
	_i=0
	while [ "$(eval "$1")" != "$2" ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "$1 is '$(eval "$1")', not '$2'"
			return 1
		fi
		sleep 0.05
	done
}

# Run $1 (printf format) in the inner pane, which then shows what it reads;
# wait until the pane has parsed it (it ends with OSC 7 "done"). The inner
# tmux must keep answering.
run() {
	timeout -s KILL 5 $INNER respawn-pane -k -t0 \
	    "stty raw -echo; printf '$1\\033]7;done\\007'; exec cat -v" || exit 1
	_i=0
	while :; do
		_p=$(timeout -s KILL 5 $INNER display -pt0 '#{pane_path}') || {
			fail "the inner tmux does not answer"
			exit 1
		}
		[ "$_p" = done ] && break
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "the pane did not finish"
			exit 1
		fi
		sleep 0.05
	done
}

# The program's answers.
answers() {
	$INNER capturep -pJt0 | grep -o '_Gi=[^^]*'
}

# What the inner tmux has sent the terminal (the outer pane).
sent() {
	cat $DIR/out
}

# A name as base64.
b64() {
	printf %s "$1" | base64 | tr -d '\n'
}

printf 'set -g status off\nset -as terminal-features ",*:kittygraphics"\n' \
    >$DIR/conf
$INNER -f$DIR/conf new -d -x 40 -y 10 'exec sleep 1000' || exit 1
$OUTER new -d -x 40 -y 10 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    || exit 1
$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
touch $DIR/go
wait_is "$INNER lsc -F '#{client_termfeatures}' | grep -o kittygraphics" \
    kittygraphics || exit 1

# A named pipe is not read (opening it would wait for a writer).
mkfifo $DIR/fifo
run "\\033_Ga=q,i=1,s=1,v=1,f=24,t=f;$(b64 $DIR/fifo)\\033\\\\"
wait_is "answers" '_Gi=1;EBADF:Failed to read image file' || exit 1

# Nor is a file with more data than tmux keeps (the file is not read).
truncate -s 300M $DIR/big
run "\\033_Ga=q,i=2,s=1,v=1,f=24,t=f;$(b64 $DIR/big)\\033\\\\"
wait_is "answers" '_Gi=2;EFBIG:Too much data'

# A temporary file is deleted in a temporary directory, not elsewhere.
printf '\377\000\000' >$DIR/a-tty-graphics-protocol
run "\\033_Ga=t,i=3,s=1,v=1,f=24,t=t;$(b64 $DIR/a-tty-graphics-protocol)\\033\\\\"
wait_is "answers" '_Gi=3;OK'
[ -e $DIR/a-tty-graphics-protocol ] && fail "temporary file not deleted"
printf '\377\000\000' >$HERE
run "\\033_Ga=t,i=4,s=1,v=1,f=24,t=t;$(b64 $HERE)\\033\\\\"
wait_is "answers" '_Gi=4;OK'
[ -e $HERE ] || fail "file outside a temporary directory deleted"

# Shared memory: the part O and S give, read (not mapped, which a program
# could truncate under tmux), then unlinked.
printf '\377\000\000\000\377\000' >/dev/shm$SHM
run "\\033_Ga=t,q=2,i=5,s=1,v=1,f=24,t=s,O=3,S=3;$(b64 $SHM)\\033\\\\"
wait_is "sent | grep -ao 'f=24,m=0;[A-Za-z0-9+/=]*' | tail -1" 'f=24,m=0;AP8A'
[ -e /dev/shm$SHM ] && fail "shared memory not unlinked"
grep -q 'mmap' ../kgfx.c && fail "kgfx.c maps files"

exit $exit_status
