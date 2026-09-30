#!/bin/sh

# The kitty graphics protocol in panes. tmux keeps a program's images and
# gives them to terminals with the protocol under ids of its own, as virtual
# placements; where the program displays an image, the pane holds Unicode
# placeholder cells, which the terminal draws the image on. An outer tmux
# stands in for the terminal (the inner tmux is told it has the protocol) and
# records what it is sent.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$"
DIR=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR' 0 1 15

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
		sleep 0.05
	done
}

# Run $1 (printf format) in the inner pane, which then shows what it reads;
# wait until the pane has parsed it (it ends with OSC 7 "done").
run() {
	$INNER respawn-pane -k -t0 \
	    "stty raw -echo; printf '$1\\033]7;done\\007'; exec cat -v" || exit 1
	wait_is "$INNER display -pt0 '#{pane_path}'" done
}

# The number of placeholder cells in the inner pane.
PH=$(printf '\364\216\273\256')
placeholders() {
	$INNER capturep -pt0 | grep -o "$PH" | wc -l
}

# What the inner tmux has sent the terminal (the outer pane).
sent() {
	cat $DIR/out
}

RED='/wAA/wAA/wAA/wAA'	# 2x2 RGB

printf 'set -g status off\nset -as terminal-features ",*:kittygraphics"\n' \
    >$DIR/conf
$INNER -f$DIR/conf new -d -x 40 -y 10 'exec sleep 1000' || exit 1
$OUTER new -d -x 40 -y 10 \
    "while [ ! -e $DIR/go ]; do sleep 0.05; done; unset TMUX; exec $INNER attach" \
    || exit 1
$OUTER pipe-pane -o "cat >$DIR/out" || exit 1
touch $DIR/go
wait_is "$INNER lsc -F '#{client_termfeatures}' | grep -o kittygraphics" \
    kittygraphics || exit 1

# a=T at 3,5 over 4x2 cells: placeholders, the cursor at the end of the last
# row (as kitty), the image and a virtual placement sent with tmux's ids and
# no answers asked for. With q=1, no answer (which would move the cursor).
run "\\033[3;5H\\033_Ga=T,q=1,i=3,f=24,s=2,v=2,c=4,r=2;$RED\\033\\\\"
wait_is placeholders 8
[ "$($INNER display -pt0 '#{cursor_x},#{cursor_y}')" = 8,3 ] ||
    fail "cursor after the image is $($INNER display -pt0 '#{cursor_x},#{cursor_y}')"
$INNER capturep -pt0 | grep -q '_Gi=3' && fail "answered with q=1"
wait_is "sent | grep -ao 'a=t,q=2,i=[0-9]*,f=24,s=2,v=2,m=0;$RED' | wc -l" 1
wait_is "sent | grep -ao 'a=p,U=1,q=2,i=[0-9]*,p=[0-9]*,c=4,r=2' | wc -l" 1

# An answer with the program's id.
run "\\033_Ga=T,i=8,f=24,s=2,v=2,c=1,r=1;$RED\\033\\\\"
wait_is "$INNER capturep -pt0 | grep -o '_Gi=8;OK'" '_Gi=8;OK'

# C=1: the cursor stays.
run "\\033[2;2H\\033_Ga=T,q=1,C=1,i=4,f=24,s=2,v=2,c=2,r=1;$RED\\033\\\\"
wait_is placeholders 2
[ "$($INNER display -pt0 '#{cursor_x},#{cursor_y}')" = 1,1 ] ||
    fail "C=1 moved the cursor to $($INNER display -pt0 '#{cursor_x},#{cursor_y}')"

# Deleting by id clears the cells and the placement on the terminal.
run "\\033[3;5H\\033_Ga=T,i=5,f=24,s=2,v=2,c=3,r=1;$RED\\033\\\\\\033_Ga=d,d=i,i=5\\033\\\\"
wait_is placeholders 0
wait_is "sent | grep -ao 'a=d,d=i,q=2,i=[0-9]*,p=[0-9]*' | wc -l" 1

# Deleting what is on the screen, freeing the data (A).
run "\\033_Ga=T,q=2,f=24,s=2,v=2,c=2,r=2;$RED\\033\\\\\\033_Ga=d,d=A\\033\\\\"
wait_is placeholders 0

# Chunks make one image.
n=$(sent | grep -ao "m=0;$RED" | wc -l)
run "\\033_Ga=T,i=6,f=24,s=2,v=2,c=1,r=1,m=1;/wAA/wAA\\033\\\\\\033_Gm=0;/wAA/wAA\\033\\\\"
wait_is placeholders 1
wait_is "sent | grep -ao 'm=0;$RED' | wc -l" $((n + 1))

# Queries: answered as kitty would, not stored.
run "\\033_Ga=q,i=31,s=1,v=1,t=d,f=24;AAAA\\033\\\\"
wait_is "$INNER capturep -pt0 | grep -o '_Gi=31;OK'" '_Gi=31;OK'
run "\\033_Ga=q,i=32,s=1,v=1,t=d,f=7;AAAA\\033\\\\"
wait_is "$INNER capturep -pJt0 | grep -o 'EINVAL:Unknown image format: 7'" \
    'EINVAL:Unknown image format: 7'
run "\\033_Ga=q,i=33,s=4,v=4,t=d,f=24;AAAA\\033\\\\"
wait_is "$INNER capturep -pJt0 | grep -o 'ENODATA:[^^]*'" \
    'ENODATA:Insufficient image data: 3 < 48'
run "\\033_Ga=p,i=77\\033\\\\"
wait_is "$INNER capturep -pJt0 | grep -o 'ENOENT:Put[^^]*'" \
    'ENOENT:Put command refers to non-existent image with id: 77 and number: 0'

# The program's own placeholders (U=1): its image id in the colour becomes
# tmux's.
run "\\033_Ga=T,q=2,U=1,i=7,f=24,s=2,v=2,c=2,r=1;$RED\\033\\\\\\033[38;5;7m$PH\\314\\205\\314\\205$PH\\314\\205\\314\\215\\033[39m"
wait_is placeholders 2
gid=$(sent | grep -ao 'a=p,U=1,q=2,i=[0-9]*,p=[0-9]*,c=2,r=1' | tail -1 |
    sed 's/.*,i=\([0-9]*\),.*/\1/')
wait_is "$INNER capturep -ept0 | grep -o '38;2;0;0;$gid' | head -1" \
    "38;2;0;0;$gid"

# A pane that goes takes its images from the terminal too.
$INNER splitw -d 'exec sleep 1000' || exit 1
n=$(sent | grep -ao 'a=d,d=I' | wc -l)
$INNER kill-pane -t0
wait_is "[ \$(sent | grep -ao 'a=d,d=I' | wc -l) -gt $n ] && echo gone" gone

exit $exit_status
