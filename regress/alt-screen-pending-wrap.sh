#!/bin/sh

# A line that fills the screen leaves the cursor one past the last column,
# where the next character wraps. Leaving the alternate screen (1049l) after
# a resize restores that cursor and must keep it there: tmux moved it back
# to the last column, so the next character overwrote the line's last one.
# A cursor saved on a wider screen (1049h, 47l, a narrower resize, 47h)
# goes to the last column, not one past it: tmux made that a pending wrap
# too, and the next character went to the line's end.

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

# Saved at column 15 of 20; 47l, 10 wide, 47h, 30 wide, 1049l.
rm -f $DIR/go
$TMUX respawn-pane -k \
    "printf 'abcdefghijklmnopqrst\\033[1;16H\\033[?1049h\\033[?47l\\033]7;one\\007'; while [ ! -e $DIR/go1 ]; do sleep 0.05; done; printf '\\033[?47h\\033]7;two\\007'; while [ ! -e $DIR/go2 ]; do sleep 0.05; done; printf '\\033[?1049lX\\033]7;three\\007'; exec sleep 1000" ||
    exit 1
$TMUX resize-window -x 20 || exit 1
wait_is "$TMUX display -p '#{pane_path}'" one
$TMUX resize-window -x 10 || exit 1
touch $DIR/go1
wait_is "$TMUX display -p '#{pane_path}'" two
$TMUX resize-window -x 30 || exit 1
touch $DIR/go2
wait_is "$TMUX display -p '#{pane_path}'" three
row=$($TMUX capture-pane -pJ | head -1)
case "$row" in
*tX)
	echo "FAIL: X went to the line's end: '$row'"
	exit 1
	;;
*X*)
	;;
*)
	echo "FAIL: no X in '$row'"
	exit 1
	;;
esac
exit 0
