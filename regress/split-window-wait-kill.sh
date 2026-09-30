#!/bin/sh

# split-window -W exit status when the pane is killed

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestSWK$$ -f/dev/null"
$TMUX kill-server 2>/dev/null
trap "$TMUX kill-server 2>/dev/null" 0 1 15

$TMUX new -d

# A command that exits on its own still reports its own status, so a failure
# below is the kill path and not -W being broken altogether.
$TMUX splitw -W 'sh -c "exit 7"'
[ "$?" = 7 ] || exit 1

$TMUX splitw -W 'sleep 60' &
pid=$!

i=0
target=
while :; do
	target=$($TMUX lsp -F'#{pane_id} #{pane_start_command}' 2>/dev/null|
	    awk '/sleep/{print $1; exit}')
	[ -n "$target" ] && break
	[ "$i" -eq 400 ] && { echo "split-window -W pane did not appear"; exit 1; }
	i=$((i + 1))
	sleep 0.05
done

$TMUX killp -t "$target"
wait "$pid"
[ "$?" = 129 ] || exit 1

exit 0
