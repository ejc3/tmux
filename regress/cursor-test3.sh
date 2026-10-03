#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
$TMUX kill-server 2>/dev/null

TMP=$(mktemp)
trap "rm -f $TMP" 0 1 15

$TMUX -f/dev/null new -d -x7 -y2 \
      "printf 'abcdefabcdefab'; printf '\e[2;7H'; cat" || exit 1
$TMUX set -g window-size manual || exit 1

# Wait for the program's output to be read: the cursor at 6,1.
n=0
until [ "$($TMUX display -p '#{cursor_x},#{cursor_y}')" = 6,1 ]; do
	n=$((n + 1))
	[ $n -gt 400 ] && { echo "output not read"; exit 1; }
	sleep 0.05
done

$TMUX display -pF '#{cursor_x} #{cursor_y} #{cursor_character}' >>$TMP
$TMUX capturep -p|awk '{print NR-1,$0}' >>$TMP
$TMUX resizew -x5 || exit 1
$TMUX display -pF '#{cursor_x} #{cursor_y} #{cursor_character}' >>$TMP
$TMUX capturep -p|awk '{print NR-1,$0}' >>$TMP
$TMUX resizew -x7 || exit 1
$TMUX display -pF '#{cursor_x} #{cursor_y} #{cursor_character}' >>$TMP
$TMUX capturep -p|awk '{print NR-1,$0}' >>$TMP

cmp -s $TMP cursor-test3.result || exit 1

$TMUX kill-server 2>/dev/null
exit 0
