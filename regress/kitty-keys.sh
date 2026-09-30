#!/bin/sh

# The kitty keyboard protocol: a program pushes, pops and sets progressive
# enhancement flags (CSI > u, CSI < u, CSI = u), asks for them (CSI ? u) and
# gets keys encoded for them. The expected bytes are what kitty sends for the
# same key (gym/refs/kitty_keys.py on the gym2 branch checks them against
# kitty). The pane shows what it reads with cat -vt.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null
CONF=$(mktemp)
trap 'rm -f $CONF; $TMUX kill-server 2>/dev/null' 0 1 15

exit_status=0

fail() {
	echo "FAIL: $*"
	exit_status=1
}

# Start the pane: it writes $1 (printf format), then asks for the flags, and
# shows what it reads. Wait until the answer is on screen; without one, tmux
# does not take part and nothing else can pass.
start() {
	$TMUX respawn-pane -k -t0 \
	    "stty raw -echo; printf '$1\\033[?u'; exec cat -vt" || exit 1
	_i=0
	until $TMUX capturep -pt0 | grep -q '\^\[\[?[0-9]*u'; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || { echo "FAIL: no answer to CSI ? u after $1"; exit 1; }
		sleep 0.05
	done
}

# What the pane has read, up to the marker "=" sent after the keys as a byte
# (so not encoded as a key).
read_keys() {
	$TMUX send-keys -H -t0 3d || exit 1
	_i=0
	until $TMUX capturep -pt0 -J | grep -q '=$'; do
		_i=$((_i + 1))
		[ $_i -lt 400 ] || { echo "(marker not read)"; return; }
		sleep 0.05
	done
	$TMUX capturep -pt0 -J | tr -d '\n' | sed 's/^\^\[\[?[0-9]*u//; s/=$//'
}

# $1 is sequences for printf; the flags in effect after them must be $2.
check_flags() {
	start "$1"
	got=$($TMUX capturep -pt0 | sed -n 's/^\^\[\[?\([0-9]*\)u.*/\1/p')
	[ "$got" = "$2" ] || fail "after '$1' flags are '$got', not '$2'"
}

# With flags $1, the tmux key $2 must reach the program as $3 (cat -vt).
check_key() {
	start "\\033[>$1u"
	$TMUX send-keys -t0 "$2" || exit 1
	got=$(read_keys)
	[ "$got" = "$3" ] || fail "flags $1, $2: got '$got', not '$3'"
}

printf 'set -s extended-keys on\nset -g status off\n' >$CONF
$TMUX -f$CONF new -d -x80 -y5 'exec sleep 1000' || exit 1

# The stack, as kitty keeps it: push, pop, set (1 sets, 2 adds, 3
# removes), one stack each for the main and alternate screens, eight deep.
check_flags '' 0
check_flags '\033[>1u' 1
check_flags '\033[>1u\033[>8u' 8
check_flags '\033[>1u\033[>8u\033[<u' 1
check_flags '\033[>1u\033[=3;1u' 3
check_flags '\033[>1u\033[=4;2u' 5
check_flags '\033[>7u\033[=1;3u' 6
check_flags '\033[>1u\033[=5u' 5
check_flags '\033[=5u' 5
check_flags '\033[=5u\033[<u' 0
check_flags '\033[>1u\033[>u' 0
check_flags '\033[>1u\033[>2u\033[<10u' 0
check_flags '\033[>255u' 127
check_flags '\033[>1u\033[?1049h' 0
check_flags '\033[>1u\033[?1049h\033[>2u' 2
check_flags '\033[>1u\033[?1049h\033[>2u\033[?1049l' 1
check_flags '\033[?1049h\033[>2u\033[?1049l\033[?1049h' 2
check_flags '\033[>1u\033[?47h\033[>4u\033[?47l' 1
check_flags '\033[>1u\033[>2u\033[>3u\033[>4u\033[>5u\033[>6u\033[>7u\033[>8u\033[>9u\033[<7u' 2
check_flags '\033[>1u\033[>2u\033[>3u\033[>4u\033[>5u\033[>6u\033[>7u\033[>8u\033[>9u\033[<8u' 0
check_flags '\033[>3u\033[?1049h\033[>4u\033c' 0
check_flags '\033[>3u\033[?1049h\033[>4u\033c\033[?1049h' 0

# The flags show in pane_key_mode.
start '\033[>5u'
got=$($TMUX display -pt0 '#{pane_key_mode}')
[ "$got" = "Kitty 5" ] || fail "pane_key_mode is '$got', not 'Kitty 5'"

# Keys. Text keys stay text with flag 1 and become escapes with flag 8;
# Enter, Tab and Backspace stay as they are unless modified or flag 8.
check_key 1 a 'a'
check_key 1 A 'A'
check_key 1 C-a '^[[97;5u'
check_key 1 M-a '^[[97;3u'
check_key 1 C-M-a '^[[97;7u'
check_key 1 M-A '^[[97;4u'
check_key 1 C-S-a '^[[97;6u'
check_key 1 '!' '!'
check_key 1 Escape '^[[27u'
check_key 1 S-Escape '^[[27;2u'
check_key 1 C-Escape '^[[27;5u'
check_key 1 Enter '^M'
check_key 1 S-Enter '^[[13;2u'
check_key 1 C-Enter '^[[13;5u'
check_key 1 M-Enter '^[[13;3u'
check_key 1 Tab '^I'
check_key 1 BTab '^[[9;2u'
check_key 1 C-Tab '^[[9;5u'
check_key 1 BSpace '^?'
check_key 1 C-BSpace '^[[127;5u'
check_key 1 M-BSpace '^[[127;3u'
check_key 1 Space ' '
check_key 1 C-Space '^[[32;5u'
check_key 1 M-Space '^[[32;3u'
check_key 1 Up '^[[A'
check_key 1 S-Up '^[[1;2A'
check_key 1 C-M-Up '^[[1;7A'
check_key 1 Home '^[[H'
check_key 1 End '^[[F'
check_key 1 PPage '^[[5~'
check_key 1 NPage '^[[6~'
check_key 1 IC '^[[2~'
check_key 1 DC '^[[3~'
check_key 1 F1 '^[[P'
check_key 1 F2 '^[[Q'
check_key 1 F3 '^[[13~'
check_key 1 F4 '^[[S'
check_key 1 F5 '^[[15~'
check_key 1 F12 '^[[24~'
check_key 1 S-F1 '^[[1;2P'
check_key 1 C-F5 '^[[15;5~'
check_key 1 S-F3 '^[[13;2~'
check_key 1 é 'M-CM-)'
check_key 8 a '^[[97u'
check_key 8 A '^[[97;2u'
check_key 8 C-a '^[[97;5u'
check_key 8 Escape '^[[27u'
check_key 8 Enter '^[[13u'
check_key 8 Tab '^[[9u'
check_key 8 BTab '^[[9;2u'
check_key 8 BSpace '^[[127u'
check_key 8 Space '^[[32u'
check_key 8 Up '^[[A'
check_key 8 F1 '^[[P'
check_key 8 é '^[[233u'
check_key 12 A '^[[97:65;2u'
check_key 12 C-S-a '^[[97:65;6u'
check_key 2 C-a '^A'
check_key 2 Escape '^['
check_key 4 M-a '^[a'
check_key 4 F1 '^[OP'
check_key 5 a 'a'
check_key 5 C-A '^[[97:65;6u'
check_key 24 a '^[[97;;97u'
check_key 24 A '^[[97;2;65u'
check_key 24 C-a '^[[97;5u'
check_key 24 M-a '^[[97;3u'
check_key 24 Enter '^[[13u'
check_key 24 é '^[[233;;233u'
check_key 31 A '^[[97:65;2;65u'

# Keypad keys (with num lock: digits give text).
check_key 1 KP1 '1'
check_key 1 KPEnter '^[[57414u'
check_key 8 KP1 '^[[57400u'
check_key 24 KP1 '^[[57400;;49u'

# With extended-keys off, tmux does not take part: no answer, keys as ever.
$TMUX set -s extended-keys off
$TMUX respawn-pane -k -t0 \
    "stty raw -echo; printf '\\033[>1u\\033[?u\\033[c'; exec cat -vt" || exit 1
_i=0
until $TMUX capturep -pt0 | grep -q 'c$'; do
	_i=$((_i + 1))
	[ $_i -lt 400 ] || { fail "no answer to DA"; break; }
	sleep 0.05
done
$TMUX capturep -pt0 | grep -q '?[0-9]*u' && fail "answered CSI ? u with extended-keys off"
$TMUX send-keys -t0 C-a || exit 1
got=$(read_keys | sed 's/^.*c//')
[ "$got" = '^A' ] || fail "extended-keys off, C-a: got '$got', not '^A'"

exit $exit_status
