#!/bin/sh

# An APC string sets the pane title (as in screen), but a kitty graphics
# command (G, then key=value pairs and a payload) is not a title.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

# Stop the server and wait until it has gone, so the next can start.
gone() {
	$TMUX kill-server 2>/dev/null
	_g=0
	while $TMUX ls >/dev/null 2>&1 && [ $_g -lt 400 ]; do
		sleep 0.05
		_g=$((_g + 1))
	done
}

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

# The pane starts titled start, then gets APC $1: the title must be $2.
check() {
	$TMUX -f/dev/null new -d -x 20 -y 4 \
	    "printf '\033]2;start\007\033_$1\033\\\\'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX display -p '#{pane_title}')
	gone
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
