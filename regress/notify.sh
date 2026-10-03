#!/bin/sh

# Notifications (OSC 9 text, OSC 99, OSC 777) from a pane reach a terminal
# with the notify feature once each, forwarding or not, and so does a query
# for what is supported (p=?), with its identifier naming the pane (one
# without is given one, notify-routing.sh); the OSC 9;4 progress bar and other
# ConEmu commands (9;9 with the directory, 9;12) are not notifications. 9;9
# sets the pane's path, as OSC 7 does, when the directory is one tmux can use
# (absolute, quoted or not; not C:\...) and OSC 7 is not giving the path. An
# outer tmux pane stands in for the terminal; what the inner client sends is
# recorded with pipe-pane.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

cat >$DIR/write.sh <<'EOS'
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033]9;one\033\\\033]99;;two\033\\\033]777;notify;three;body\033\\'
printf '\033]99;i=1:p=?;\033\\\033]9;4;1;50\033\\done\r\n'
printf '\033]9;9;"/tmp/a b"\033\\\033]9;12\033\\\033]9;9;C:\\Users\\me\033\\\033]9;9;"C:\\quoted"\033\\'
printf '=END='
touch "$1/done"
exec sleep 100000
EOS

wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.05
	done
}

# forward-output $1.
run() {
	rm -f $DIR/go $DIR/done $DIR/out
	$OUTER new -d -s keep \; set -g default-terminal xterm-256color \; \
	    set -g status off || exit 1
	$INNER new -d -s inner -x 80 -y 24 "sh $DIR/write.sh $DIR" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features ',xterm*:notify' || exit 1
	$INNER show -s forward-output >/dev/null 2>&1 &&
	    { $INNER set -s forward-output $1 || exit 1; }
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1
	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 100 || exit 1
	wait_for "[ -n \"\$($INNER display -p '#{client_termtype}' 2>/dev/null)\" ]" 400 ||
	    exit 1
	$OUTER pipep -O -t =tmux: "cat >$DIR/out" || exit 1
	touch $DIR/go
	wait_for "grep -q =END= $DIR/out 2>/dev/null" 400 ||
	    { echo "output did not arrive"; exit 1; }
	path=$($INNER display -p -t inner '#{pane_path}')
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file' && $OUTER ls 2>&1 | grep -qE 'no server running|No such file'" 100
}
count() {
	grep -aoF "$(printf "$1")" $DIR/out | wc -l
}
for mode in on off; do
	run $mode
	for n in '\033]9;one' '.0;two' '\033]777;notify;three;body'; do
		[ "$(count "$n")" = 1 ] || {
			echo "forward-output $mode: $n sent $(count "$n") times"
			exit 1
		}
	done
	[ "$(count '\033]99;i=t')" = 2 ] && [ "$(count 'p=?')" = 1 ] ||
	    { echo "forward-output $mode: query not sent once"; exit 1; }
	[ "$(count '\033]9;9')" = 0 ] && [ "$(count '\033]9;12')" = 0 ] ||
	    { echo "forward-output $mode: ConEmu command sent"; exit 1; }
	[ "$(count '\033]9;4')" -le 1 ] || { echo "forward-output $mode: progress repeated"; exit 1; }
	[ "$path" = '/tmp/a b' ] ||
	    { echo "forward-output $mode: 9;9 left the pane's path '$path'"; exit 1; }
done

# 9;9 unquoted; then, once OSC 7 gives the path, 9;9 leaves it. The title,
# set last, shows when all of it has been read.
path_after() {
	$INNER new -d -x 80 -y 24 "printf '$1\\033]2;read\\033\\\\'; exec sleep 1000" ||
	    exit 1
	wait_for "[ \"\$($INNER display -p '#{pane_title}')\" = read ]" 400 ||
	    { echo "9;9: output not read"; exit 1; }
	$INNER display -p '#{pane_path}'
	$INNER kill-server 2>/dev/null
	wait_for "$INNER ls 2>&1 | grep -qE 'no server running|No such file'" 100
}
p=$(path_after '\033]9;9;/tmp/plain\007')
[ "$p" = /tmp/plain ] || { echo "unquoted 9;9 left the path '$p'"; exit 1; }
p=$(path_after '\033]7;file://host/dir\007\033]9;9;/tmp/other\007')
[ "$p" = file://host/dir ] || { echo "9;9 after OSC 7 left the path '$p'"; exit 1; }
# A directory with :// in it is still a directory, which the next replaces.
p=$(path_after '\033]9;9;/odd/a://b\007\033]9;9;/tmp/next\007')
[ "$p" = /tmp/next ] || { echo "9;9 after a directory with :// left '$p'"; exit 1; }
exit 0
