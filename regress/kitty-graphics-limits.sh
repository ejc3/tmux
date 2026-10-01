#!/bin/sh

# The kitty graphics protocol's limits in tmux: at most so many placements
# and images (the oldest go, with their placeholders), and an image is sent
# whole to a terminal however far behind it is. An outer tmux stands in for
# the terminal (the inner tmux is told it has the protocol) and records what
# it is sent.

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

# Write $DIR/in in the inner pane; wait until the pane has parsed it (it ends
# with OSC 7 naming the run).
N=0
run() {
	N=$((N + 1))
	printf '\033]7;done%s\007' $N >>$DIR/in
	mv $DIR/in $DIR/in$N
	$INNER respawn-pane -k -t0 \
	    "stty raw -echo; cat $DIR/in$N; exec cat -v" || exit 1
	wait_is "$INNER display -pt0 '#{pane_path}'" done$N
}

# The number of placeholder cells in the inner pane.
PH=$(printf '\364\216\273\256')
placeholders() {
	$INNER capturep -pt0 | grep -o "$PH" | wc -l
}

# The number of times the inner tmux has sent the terminal $1.
sent() {
	grep -aoF -- "$1" $DIR/out | wc -l
}

RED='/wAA'	# 1x1 RGB

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

# An image of 1 MB (more than the terminal reads at once) is sent whole.
head -c 786432 /dev/zero | base64 | tr -d '\n' | fold -w 4096 |
    awk 'NR == 1 { printf "\033_Ga=t,q=2,i=1,f=24,s=512,v=512,m=1;%s\033\\", $0; next }
	{ printf "\033_Gm=1;%s\033\\", $0 }
	END { printf "\033_Gm=0;\033\\" }' >$DIR/in
run
wait_is "sent 'Gm=0,q=2;'" 1
[ "$(sent 'Gm=1,q=2;')" = 254 ] ||
    fail "$(sent 'Gm=1,q=2;') of 254 middle chunks sent"

# More than 16384 placements: the oldest go.
printf "\033_Ga=t,q=2,i=2,f=24,s=1,v=1;$RED\033\\\\" >$DIR/in
awk 'BEGIN { for (i = 0; i < 16394; i++) printf "\033_Ga=p,U=1,q=2,i=2\033\\" }' \
    >>$DIR/in
run
wait_is "sent 'a=d,d=i,q=2,'" 10

# More than 4096 images: the oldest go, and their placeholders.
printf "\033[H\033_Ga=T,q=2,i=3,f=24,s=1,v=1,c=1,r=1;$RED\033\\\\" >$DIR/in
printf '\033]7;shown\007' >>$DIR/in
awk -v red=$RED 'BEGIN { for (i = 0; i < 4096; i++)
	printf "\033_Ga=t,q=2,i=%u,f=24,s=1,v=1;%s\033\\", 100 + i, red }' \
    >$DIR/more
printf '\033]7;evicted\007' >>$DIR/more
$INNER respawn-pane -k -t0 "stty raw -echo; cat $DIR/in; while [ ! -e $DIR/go2 ]; do sleep 0.05; done; cat $DIR/more; exec cat -v" ||
    exit 1
wait_is "$INNER display -pt0 '#{pane_path}'" shown
wait_is placeholders 1
touch $DIR/go2
wait_is "$INNER display -pt0 '#{pane_path}'" evicted
wait_is placeholders 0

# Chunks being put together are within the same limit on data.
grep -q 'kgfx_fits(pd->size, n) || !kgfx_fits(kgfx_pending_size, n)' \
    ../kgfx.c || fail "chunks not limited"

exit $exit_status
