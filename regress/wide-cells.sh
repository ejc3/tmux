#!/bin/sh

# Characters 1 to 6 cells wide (OSC 66 w=N gives a width; 6 is the widest a
# cell holds) at each column near the right edge, with and without insert
# mode, then an edit over the character or inside it: ICH, DCH, ECH, EL, ED,
# a character written over it. After each, and after reflowing narrower than
# the character and back, a selection copied and captures, the server must be
# alive (a sanitizer build stops it on an error), the cursor in the pane and
# no row wider than the pane but for a character a reflow left overhanging
# one; and the reflow to 4 columns and back gives the same lines (no
# character is lost), with the cursor, if it is on a character, still on it.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest$$ -f/dev/null"
DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

SX=10
SY=12
E=$(printf '\033')

exit_status=0
fail() {
	echo "FAIL: $*"
	exit_status=1
}

# Wait until $1 prints $2.
wait_is() {
	_i=0
	while [ "$(eval "$1")" != "$2" ]; do
		_i=$((_i + 1))
		if [ $_i -ge 400 ]; then
			fail "$1 is '$(eval "$1")', not '$2'"
			return 1
		fi
		sleep 0.01
	done
}

# Check the output of $2 (tmux commands that end with the cursor, the pane
# width and the pane captured with -e); $1 says which step it was.
check() {
	_out=$($TMUX $2 \; display -p '#{cursor_x} #{cursor_y} #{pane_width}' \; \
	    capturep -pe) || { fail "$1: the server died"; exit 1; }
	echo "$_out" | sed -e "s/$E\[[0-9;:]*m//g" \
	    -e "s/$E]66;w=1;[^$E]*$E\\\\/1/g" \
	    -e "s/$E]66;w=2;[^$E]*$E\\\\/22/g" \
	    -e "s/$E]66;w=3;[^$E]*$E\\\\/333/g" \
	    -e "s/$E]66;w=4;[^$E]*$E\\\\/4444/g" \
	    -e "s/$E]66;w=5;[^$E]*$E\\\\/55555/g" \
	    -e "s/$E]66;w=6;[^$E]*$E\\\\/666666/g" |
	    awk -v step="$1" -v sy=$SY '
		/^[0-9]+ [0-9]+ [0-9]+$/ && !seen {
			seen = 1; w = $3
			if ($1 > w || $2 >= sy)
				print "FAIL: " step ": cursor " $1 "," $2 \
				    " outside the pane"
			next
		}
		# Wider than the pane only as one character a reflow left
		# overhanging a row of its own.
		seen && length($0) > w &&
		    $0 !~ /^(22|333|4444|55555|666666)$/ {
			print "FAIL: " step ": a row is " length($0) " columns"
		}' >$DIR/fail
	if [ -s $DIR/fail ]; then
		cat $DIR/fail
		exit_status=1
	fi
}

# Run $2 (printf format) in the pane and do the checks, also after a reflow
# to 4 columns and back, with a selection copied.
run() {
	# respawn-pane keeps the last path: a new marker each run.
	DONE=$((DONE + 1))
	$TMUX respawn-pane -k "printf '$2\\033]7;done$DONE\\007'; exec cat" ||
	    exit 1
	wait_is "$TMUX display -p '#{pane_path}'" done$DONE || exit 1
	check "$1" "capturep -pC ; capturep -pJ"
	before=$($TMUX capturep -peJ -S -)
	cb=$($TMUX display -p '#{cursor_x},#{cursor_y}=#{cursor_character}=')
	check "$1 at 4" "resize-window -x 4"
	c4=$($TMUX display -p '#{cursor_character}')
	check "$1 copied at 4" "copy-mode ; send -X history-top ; \
	    send -X begin-selection ; send -X cursor-down ; \
	    send -X cursor-right ; send -X copy-selection-and-cancel ; showb"
	check "$1 back" "resize-window -x $SX"
	after=$($TMUX capturep -peJ -S -)
	ca=$($TMUX display -p '#{cursor_x},#{cursor_y}=#{cursor_character}=')
	[ "$before" = "$after" ] ||
		fail "$1: not the same after a reflow to 4 and back"
	# The cursor on a character stays on it.
	case "$cb" in
	*==|*=\ =) ;;
	*)	[ "=$c4=" = "=${cb#*=}" ] && [ "$ca" = "$cb" ] ||
		    fail "$1: cursor $cb, at 4 on '$c4', back $ca" ;;
	esac
	check "$1 copied" "copy-mode ; send -X history-top ; \
	    send -X begin-selection ; send -X cursor-down ; \
	    send -X cursor-right ; send -X cursor-right ; \
	    send -X copy-selection-and-cancel ; copy-mode ; \
	    send -X history-top ; send -X select-line ; \
	    send -X copy-selection-and-cancel ; showb"
}

$TMUX new -d -x $SX -y $SY 'exec cat' \; set -g status off \; \
    set -g history-limit 50 || exit 1

A=aaaaaaaaaa
OPS="@ 2@ P 2P X 2X K 1K Q IQ"
for w in 1 2 3 4 5 6; do
	for irm in 0 1; do
		on=; off=
		[ $irm = 1 ] && on='\033[4h' && off='\033[4l'
		xs=$(printf '%s\n' $((SX - w - 1)) $((SX - w)) $((SX - w + 1)) \
		    $((SX - 1)) | sort -un)
		for x in $xs; do
			for in in 0 1; do
				[ $in = 1 ] && [ $w = 1 ] && continue
				c=$((x + in))
				[ $c -ge $SX ] && continue
				s=; y=1; d="w=$w irm=$irm x=$x c=$c"
				for op in $OPS; do
					case $op in
					Q) o=Q ;;
					IQ) o='\033[4hQ\033[4l' ;;
					*) o="\\033[$op" ;;
					esac
					s="$s\\033[$y;1H$A\\033[$y;$((x + 1))H$on\\033]66;w=$w;X\\007$off\\033[$y;$((c + 1))H$o"
					y=$((y + 2))
					if [ $y -ge $SY ]; then
						run "$d $op" "$s"
						s=; y=1
					fi
				done
				[ -n "$s" ] && run "$d" "$s"
				for op in J 1J; do
					run "$d $op" "\\033[3;1H$A\\033[3;$((x + 1))H$on\\033]66;w=$w;X\\007$off\\033[3;$((c + 1))H\\033[$op"
				done
			done
		done
	done
done

exit $exit_status
