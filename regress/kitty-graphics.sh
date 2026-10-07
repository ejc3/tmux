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
	# respawn-pane keeps the last path: a new marker each run.
	DONE=$((DONE + 1))
	$INNER respawn-pane -k -t0 \
	    "stty raw -echo; printf '$1\\033]7;done$DONE\\007'; exec cat -v" || exit 1
	wait_is "$INNER display -pt0 '#{pane_path}'" done$DONE
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

# Wait until all the inner tmux has written to the terminal so far is in
# $DIR/out, which it reaches through the outer pane and pipe-pane: give the
# terminal a new title and wait for it.
FLUSH=0
flushed() {
	FLUSH=$((FLUSH + 1))
	$INNER set -g set-titles-string "flushed$FLUSH" || exit 1
	wait_is "sent | grep -aq 'flushed$FLUSH' && echo y" y
}

RED='/wAA/wAA/wAA/wAA'	# 2x2 RGB

printf '%s\n' 'set -g status off' 'set -g set-titles on' \
    'set -as terminal-features ",*:kittygraphics:title"' >$DIR/conf
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
flushed
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
flushed
gid=$(sent | grep -ao 'a=p,U=1,q=2,i=[0-9]*,p=[0-9]*,c=2,r=1' | tail -1 |
    sed 's/.*,i=\([0-9]*\),.*/\1/')
wait_is "$INNER capturep -ept0 | grep -o '38;2;0;0;$gid' | head -1" \
    "38;2;0;0;$gid"

# tmux's id for an image: run $1, which transmits one, and set G to the id
# the terminal was sent it with, and RGB to it as a colour. The image's last
# pixel is made different each time, so its transmission is told from the
# others, which can still be on their way to the terminal.
TX=0
transmit() {
	TX=$((TX + 1))
	_p=$({ printf '\377\000\000\377\000\000\377\000\000\377\000'
	    printf "\\$(printf %o $TX)"; } | base64 | tr -d '\n')
	run "$(printf '%s' "$1" | sed "s|$RED|$_p|")"
	wait_is "sent | grep -aq 'a=t,q=2,i=[0-9]*[^;]*;$_p' && echo sent" sent
	G=$(sent | grep -ao "a=t,q=2,i=[0-9]*[^;]*;$_p" | head -1 |
	    sed 's/^a=t,q=2,i=\([0-9]*\).*/\1/')
	RGB="$((G >> 16));$(((G >> 8) & 255));$((G & 255))"
}

# The program's answers.
answers() {
	$INNER capturep -pJt0 | grep -o '_Gi=[^^]*'
}

# Sending an image again with its id keeps tmux's id, which the program's
# placeholders have.
transmit "\\033_Ga=t,q=2,i=60,f=24,s=2,v=2;$RED\\033\\\\"
g=$G
transmit "\\033_Ga=t,q=2,i=60,f=24,s=2,v=2;$RED\\033\\\\"
[ "$G" = "$g" ] || fail "image 60 sent again is $G, not $g"

# An image with only a number gets an id no image of the pane has: here the
# next of tmux's ids is the program's id of an image.
transmit "\\033_Ga=t,q=2,i=61,f=24,s=2,v=2;$RED\\033\\\\"
n=$((G + 2))
run "\\033_Ga=t,q=2,i=$n,f=24,s=2,v=2;$RED\\033\\\\\\033_Ga=t,I=7,f=24,s=2,v=2;$RED\\033\\\\"
wait_is "answers | grep -c ',I=7;OK'" 1
[ "$(answers | grep ',I=7;OK')" != "_Gi=$n,I=7;OK" ] ||
    fail "the id given for number 7 is image $n's"

# Data that is not base64 is ignored, as kitty ignores it; PNG and
# compressed data are checked as far as their headers.
run "\\033_Ga=t,i=71,f=24,s=1,v=1;AA*A\\033\\\\\\033_Ga=p,i=71\\033\\\\"
wait_is "answers | grep -c 'i=71;ENOENT'" 1
[ "$(answers | grep -c 'i=71;OK')" = 0 ] || fail "answered data not base64"
run "\\033_Ga=t,i=72,f=100;AAAAAAAA\\033\\\\"
wait_is "answers" \
    '_Gi=72;EBADPNG:The supplied data of 6 bytes is not a valid PNG image'
run "\\033_Ga=t,i=73,f=24,s=1,v=1,o=z;AAAA\\033\\\\"
wait_is "answers" \
    '_Gi=73;EINVAL:Failed to inflate image data with error: incorrect header check'

# Deleting the last placement with a capital deletes the image.
run "\\033_Ga=T,q=2,i=50,p=5,f=24,s=2,v=2,c=1,r=1;$RED\\033\\\\\\033_Ga=d,d=I,i=50,p=5\\033\\\\\\033_Ga=p,i=50\\033\\\\"
wait_is "answers | grep -c 'i=50;ENOENT'" 1

# A delete stops a transmission in chunks.
run "\\033_Ga=t,q=2,i=70,f=24,s=2,v=2,m=1;$RED\\033\\\\\\033_Ga=d,d=i,i=99\\033\\\\\\033_Ga=p,i=70\\033\\\\"
wait_is "answers | grep -c 'i=70;ENOENT'" 1

# An image deleted while the alternate screen is in use goes from the
# screen saved too.
run "\\033[H\\033_Ga=T,q=2,i=51,f=24,s=2,v=2,c=2,r=1;$RED\\033\\\\\\033[?1049h\\033_Ga=d,d=I,i=51\\033\\\\\\033[?1049l"
wait_is placeholders 0

# The program's placeholder for an image (or a placement) it does not have
# names none, not another pane's.
run "\\033[38;5;99m$PH\\314\\205\\314\\205\\033[m"
$INNER capturep -ept0 | grep -q '38;5;99' && fail "unknown image 99 kept"
$INNER capturep -ept0 | grep -q '38;2;0;0;0m' || fail "unknown image 99 not 0"
run "\\033_Ga=T,q=2,U=1,i=52,f=24,s=2,v=2,c=1,r=1;$RED\\033\\\\\\033[38;5;52;58;5;9m$PH\\314\\205\\314\\205\\033[m"
$INNER capturep -ept0 | grep -q '58;2;255;255;255m' ||
    fail "unknown placement 9: $($INNER capturep -ept0 | head -1 | cat -v)"

# A third diacritic gives the high byte of the image id; the next placeholder
# with the same colours has it too. The terminal gets tmux's id without it.
transmit "\\033_Ga=T,q=2,U=1,i=16777221,f=24,s=2,v=2,c=2,r=1;$RED\\033\\\\"
run "\\033[38;5;5m$PH\\314\\205\\314\\205\\314\\215$PH\\033[m"
[ "$($INNER capturep -ept0 | head -1 | grep -o '38;[0-9;]*m')" = "38;2;${RGB}m" ] ||
    fail "image 16777221 placeholders: $($INNER capturep -ept0 | head -1 | cat -v)"
$INNER capturep -pt0 | grep -q "$(printf '\314\215')" &&
    fail "the third diacritic was kept"
BIG=$RGB

# As kitty, a placeholder with only a row has the high byte of the one to its
# left if it is on the same row, and one with a row and column if its column
# is the next (here image 5 is the image with the low bytes alone).
transmit "\\033_Ga=t,q=2,i=5,f=24,s=2,v=2;$RED\\033\\\\"
run "\\033[38;5;5m$PH\\314\\205\\314\\205\\314\\215$PH\\314\\215\\033[m"
[ "$($INNER capturep -ept0 | head -1 | grep -o '38;[0-9;]*m' | tr '\n' ' ')" = "38;2;${BIG}m 38;2;${RGB}m " ] ||
    fail "next row: $($INNER capturep -ept0 | head -1 | cat -v)"
run "\\033[38;5;5m$PH\\314\\205\\314\\205\\314\\215$PH\\314\\205\\033[m"
[ "$($INNER capturep -ept0 | head -1 | grep -o '38;[0-9;]*m' | tr '\n' ' ')" = "38;2;${BIG}m " ] ||
    fail "same row: $($INNER capturep -ept0 | head -1 | cat -v)"
run "\\033[38;5;5m$PH\\314\\205\\314\\205\\314\\215$PH\\314\\205\\314\\216\\033[m"
[ "$($INNER capturep -ept0 | head -1 | grep -o '38;[0-9;]*m' | tr '\n' ' ')" = "38;2;${BIG}m 38;2;${RGB}m " ] ||
    fail "not the next column: $($INNER capturep -ept0 | head -1 | cat -v)"

# A placeholder written again for its high byte is written in place, also in
# insert mode.
run "XYZ\\r\\033[4h\\033[38;5;5m$PH\\314\\205\\314\\205\\314\\215\\033[m\\033[4l"
[ "$(placeholders)" = 1 ] || fail "insert mode: $(placeholders) placeholders"
[ "$($INNER capturep -pt0 | head -1 | sed "s/$PH[^X]*//")" = XYZ ] ||
    fail "insert mode: $($INNER capturep -pt0 | head -1 | cat -v)"

# A pane that has not used kitty graphics through tmux has its placeholders
# as written (for kitty graphics passed through to the terminal).
$INNER neww -d -n passthrough \
    "printf '\\033[38;5;42m$PH\\314\\205\\314\\205\\314\\216\\033[m\\033]7;done\\007'; exec cat" ||
    exit 1
wait_is "$INNER display -pt:passthrough '#{pane_path}'" done
[ "$($INNER capturep -ept:passthrough | head -1 | cat -v)" = "$(printf '\033[38;5;42m%s\314\205\314\205\314\216\033[39m' "$PH" | cat -v)" ] ||
    fail "passthrough placeholder: $($INNER capturep -ept:passthrough | head -1 | cat -v)"

# Frames have their format and compression and are read from files as
# images are.
transmit "\\033_Ga=t,q=2,i=80,f=24,s=2,v=2;$RED\\033\\\\"
run "\\033_Ga=f,q=2,i=80,s=1,v=1,f=24,o=z;eJwA\\033\\\\"
wait_is "sent | grep -ao 'a=f,q=2,i=$G,s=1,v=1,f=24,o=z,m=0;eJwA' | wc -l" 1
printf '\000\377\000' >$DIR/frame
P=$(printf %s "$DIR/frame" | base64 | tr -d '\n')
run "\\033_Ga=f,q=2,i=80,t=f,s=1,v=1,f=24;$P\\033\\\\"
wait_is "sent | grep -ao 'a=f,q=2,i=$G,s=1,v=1,f=24,m=0;AP8A' | wc -l" 1

# A pane that goes takes its images from the terminal too.
$INNER splitw -d 'exec sleep 1000' || exit 1
flushed
n=$(sent | grep -ao 'a=d,d=I' | wc -l)
$INNER kill-pane -t0
wait_is "[ \$(sent | grep -ao 'a=d,d=I' | wc -l) -gt $n ] && echo gone" gone

exit $exit_status
