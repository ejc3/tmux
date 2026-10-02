#!/bin/sh

# A line that fills the screen leaves the cursor one past the last column,
# where the next character wraps. Leaving the alternate screen (1049l) after
# a resize restores that cursor and must keep it there: tmux moved it back
# to the last column, so the next character overwrote the line's last one.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

wait_is() {
	_i=0
	while [ "$(eval "$1")" != "$2" ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			echo "FAIL: $1 is '$(eval "$1")', not '$2'"
			exit 1
		fi
		sleep 0.05
	done
}

$TMUX new -d -x 10 -y 5 \
    "printf 'abcdefghij\\033[?1049h\\033]7;in\\007'; while [ ! -e $DIR/go ]; do sleep 0.05; done; printf '\\033[?1049lX\\033]7;done\\007'; exec sleep 1000" ||
    exit 1
$TMUX set -g window-size manual || exit 1
wait_is "$TMUX display -p '#{pane_path}'" in
$TMUX resize-window -x 20 || exit 1
touch $DIR/go
wait_is "$TMUX display -p '#{pane_path}'" done
row=$($TMUX capture-pane -p | head -1)
if [ "$row" != abcdefghijX ]; then
	echo "FAIL: the row is '$row', not 'abcdefghijX'"
	exit 1
fi
exit 0
