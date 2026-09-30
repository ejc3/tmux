#!/bin/sh

# An APC string sets the pane title (as in screen), but a kitty graphics
# command (G, then key=value pairs and a payload) is not a title.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# The pane starts titled start, then gets APC $1: the title must be $2.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf '\033]2;start\007\033_$1\033\\\\'; sleep 1000" || exit 1
	sleep 0.5
	out=$($TMUX display -p '#{pane_title}')
	$TMUX kill-server 2>/dev/null
	[ "$out" = "$2" ] || {
		echo "APC '$1': title '$out', want '$2'"
		exit 1
	}
}
check 'Ga=T,f=100;iVBORw0KGgo=' start
check 'Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA' start
check 'Ga=d' start
check 'Gvim' Gvim
check 'hello' hello
exit 0
