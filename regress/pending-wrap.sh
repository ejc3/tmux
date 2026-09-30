#!/bin/sh

# A full row leaves the cursor waiting to wrap at the last column. Controls
# other than a character act at the last column and end the wait, as in
# xterm, Ghostty, VTE and libvterm: erases, inserts and deletes reach the
# last character, backspace and CUB count from the last column, and the
# next character stays on the row. DECSC and DECRC keep the wait. IL and DL
# also return the cursor to the first column.

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

# abcdefghij fills a 10-column row, then $1 and an x (a line feed is not
# turned into CR LF); rows 1 and 2 must be $2 and $3.
check() {
	$TMUX -f/dev/null new -d -x 10 -y 4 \
	    "stty -onlcr; printf 'abcdefghij$1x'; printf '\033]7;done\007'; sleep 1000" || exit 1
	finished || exit 1
	out=$($TMUX capturep -p | sed -n 1,2p | tr '\n' '|')
	gone
	[ "$out" = "$2|$3|" ] || {
		echo "$4: '$out', want '$2|$3|'"
		exit 1
	}
}
check '\033[X' abcdefghix '' ECH
check '\033[K' abcdefghix '' EL0
check '\033[P' abcdefghix '' DCH
check '\033[@' abcdefghix '' ICH
check '\033[J' abcdefghix '' ED0
check '\033[2K' '         x' '' EL2
check '\033[D' abcdefghxj '' CUB
check '\010' abcdefghxj '' BS
check '\033[2D' abcdefgxij '' CUB2
check '\033[?7l' abcdefghix '' DECAWM
check '\033[a' abcdefghix '' HPR
check '\n' abcdefghij '         x' LF
check '\033D' abcdefghij '         x' IND
check '\033[2d' abcdefghij '         x' VPA
check '\0337\033[3;3H\0338' abcdefghij x DECSC
check '\033[s\033[3;3H\033[u' abcdefghij x SCOSC
check '\033[L' x abcdefghij IL
check '\033[M' x '' DL
check '\r\033[3C\033[L' x abcdefghij IL-column
exit 0
