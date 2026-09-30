#!/bin/sh

# A line a scroll region pushes into the history joins only what continues
# it: when the region's new top row is rewritten before the next push, the
# line pushed then is not joined to the one before.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
SCRIPT=$(mktemp)
trap "rm -f $TMP $SCRIPT; $TMUX kill-server 2>/dev/null" 0 1 15

# Wait until the pane's program has written everything: it ends with an OSC 7
# path of done, which tmux reads after all that came before.
finished() {
	_f=0
	until [ "$($TMUX display -p '#{pane_path}' 2>/dev/null)" = done ]; do
		_f=$((_f + 1))
		[ $_f -gt 400 ] && { echo "program did not finish"; return 1; }
		sleep 0.05
	done
}

# Rows 2-4 are the region; a 50-column line wraps from row 2 into row 3.
cat >$SCRIPT <<'EOS'
a=$(printf '%50s' '' | tr ' ' a)
printf '\033[2;4r\033[2;1H%s\033[4;1H\n' "$a"
printf '\033[2;1H\033[2Kunrelated\033[4;1H\n\033[r'
printf '\033]7;done\007'
exec cat
EOS
$TMUX new -d -x40 -y10 "sh $SCRIPT" || exit 1
finished || exit 1

$TMUX capturep -pJ -S- -E- >$TMP
grep -qx 'a\{40\}' $TMP || { cat $TMP; exit 1; }
grep -qx 'unrelated' $TMP || { cat $TMP; exit 1; }

$TMUX kill-server 2>/dev/null
exit 0
