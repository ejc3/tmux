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

# Rows 2-4 are the region; a 50-column line wraps from row 2 into row 3.
cat >$SCRIPT <<'EOS'
a=$(printf '%50s' '' | tr ' ' a)
printf '\033[2;4r\033[2;1H%s\033[4;1H\n' "$a"
printf '\033[2;1H\033[2Kunrelated\033[4;1H\n\033[r'
touch "$1"
exec cat
EOS
$TMUX new -d -x40 -y10 "sh $SCRIPT $TMP.done" || exit 1
n=0
while [ ! -e $TMP.done ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
rm -f $TMP.done
sleep 0.2

$TMUX capturep -pJ -S- -E- >$TMP
grep -qx 'a\{40\}' $TMP || { cat $TMP; exit 1; }
grep -qx 'unrelated' $TMP || { cat $TMP; exit 1; }

$TMUX kill-server 2>/dev/null
exit 0
