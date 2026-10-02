#!/bin/sh

# An integer format expression whose result is not a number (0 % 0) or does
# not fit (1 / 0) fails, as other bad expressions do, rather than converting
# it to an integer, which is undefined (it gave 0 and 9223372036854775808 on
# one machine). Floating point (|f) still gives inf.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
trap '$TMUX kill-server 2>/dev/null' 0 1 15

$TMUX new -d 'exec sleep 1000' || exit 1
exit_status=0
check() {
	_got=$($TMUX display -p "[$1]")
	if [ "$_got" != "[$2]" ]; then
		echo "FAIL: $1 is $_got, not [$2]"
		exit_status=1
	fi
}
check '#{e|%:,}' ''
check '#{e|%:7,0}' ''
check '#{e|/:1,0}' ''
check '#{e|*:3,4}' 12
check '#{e|%:7,4}' 3
check '#{e|/|f:1,0}' inf
exit $exit_status
