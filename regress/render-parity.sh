#!/bin/sh

# Render parity: output must leave a terminal the same whether a program runs
# directly in it or inside tmux. Two panes of an outer tmux stand in for the
# terminal. For each case, one pane runs the case's writer
# directly; the other runs an inner tmux client whose pane runs the same
# writer. The outer panes' history and screen are then compared: text with
# attributes and hyperlinks (capture-pane -e), soft-wrapped lines (-J), the
# cursor and which screen is active.
#
# The inner server keeps the terminal's scrollback (clear-on-attach off) and
# is told the terminal can draw hyperlinks, styled underlines and RGB colour.
# The outer server, the terminal, has clear-on-attach off too, so it keeps
# its scrollback as terminals do: nothing from an ED 0 at the top left
# (scroll-on-clear).
# A case is a set of chunks written in order with a pause between, so tmux
# sends what came before a chunk before it reads the chunk; the cases are
# written by cases.awk below. A case marked to differ is expected to, for the
# reason given, and does not fail the test.
#
# RENDER_PARITY_CASES selects cases by name; RENDER_PARITY_DIR reads cases
# from a directory instead (NAME/1, NAME/2, ... and NAME/differ).
# RENDER_PARITY_FORWARD=off turns forward-output off, so the pane is drawn
# from the grid rather than forwarded as written.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL
E=$(printf '\033')

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
OUTER="$TEST_TMUX -LtestA$$ -f/dev/null"
INNER="$TEST_TMUX -LtestB$$ -f/dev/null"
DIR=$(mktemp -d)
CASES=${RENDER_PARITY_DIR:-$DIR/cases}
trap "$OUTER kill-server 2>/dev/null; $INNER kill-server 2>/dev/null; rm -rf $DIR" 0 1 15

# The writer: wait to be told to start, write a marker and scroll it into the
# history (what came before - attaching the inner client moves the outer
# screen into history - is not compared), write each chunk with a pause after
# it, then stay.
cat >$DIR/write.sh <<'EOF'
while [ ! -e "$2" ]; do sleep 0.05; done
printf '\033[H\033[2J@@render-parity@@\r\n'
i=0; while [ $i -lt 24 ]; do printf '\r\n'; i=$((i + 1)); done
sleep 0.3
for f in $(ls "$1" | grep -E '^[0-9]+$' | sort -n); do
	cat "$1/$f"
	sleep 0.3
done
touch "$3"
exec sleep 100000
EOF

# The cases, each a directory of chunks: NAME/1, NAME/2, ... and NAME/differ
# with the reason when it is expected to differ; "list" names them in order.
# The named cases cover one terminal feature each; fuzz-NN mix them at random.
# Nothing is specific to any application: the inner process only writes the
# bytes. Random text comes from a generator of its own (Park-Miller), so any
# awk writes the same bytes; characters outside ASCII are written as octal.
cat >$DIR/cases.awk <<'EOF'
function rnd(n) { seed = (seed * 16807) % 2147483647; return seed % n }
function between(a, b) { return a + rnd(b - a + 1) }
function reseed(s) { seed = s + 1; rnd(1) }
function rep(s, n,	o) { o = ""; while (n-- > 0) o = o s; return o }
function one(chars) { return substr(chars, rnd(length(chars)) + 1, 1) }
function any(list,	a, n) { n = split(list, a, "|"); return a[rnd(n) + 1] }
function link(url, text, id) {
	return E "]8;" id ";" url E "\\" text E "]8;;" E "\\"
}
function start(n) {
	name = n; chunks = 0
	system("mkdir -p '" dir "/" n "'")
	print n >(dir "/list")
}
function k(s,	f) {
	f = dir "/" name "/" (++chunks); printf "%s", s >f; close(f)
}
function differ(why,	f) {
	f = dir "/" name "/differ"; print why >f; close(f)
}
# n numbered lines of up to width random letters and spaces.
function lines(n, width, s,	i, j, w, o, t) {
	reseed(s); o = ""
	for (i = 0; i < n; i++) {
		w = rnd(width + 1); t = ""
		for (j = 0; j < w; j++)
			t = t one("abcdefghij klmnop")
		o = o sprintf("line %03d %s", i, t) "\r\n"
	}
	return o
}
function text(	t, n, i, o) {
	t = any("ascii|ascii|wide|emoji|exact|long"); o = ""
	if (t == "ascii") {
		n = between(1, 40)
		for (i = 0; i < n; i++) o = o one(ASCII)
	} else if (t == "wide") {
		n = between(1, 20)
		for (i = 0; i < n; i++) o = o any(WIDE)
	} else if (t == "emoji") {
		n = between(1, 6)
		for (i = 0; i < n; i++) o = o any(EMOJI)
	} else if (t == "exact") {
		for (i = 0; i < 80; i++) o = o one(substr(ASCII, 1, 62))
	} else {
		n = between(80, 320)
		for (i = 0; i < n; i++) o = o one(ASCII)
	}
	return o
}
# About 40 operations of every kind above, in five chunks; with pick (a list
# of operation numbers), only those, in the chunks they fall in.
function fuzz(s, pick,	ops, n, i, j, w, t, b, m, o, cut, ncut, c, keep, np, pk) {
	reseed(1000 + s)
	for (n = 0; n < 40; n++) {
		w = rnd(98)
		if ((w -= 30) < 0) o = text()
		else if ((w -= 18) < 0) o = any("\r\n|\n|\r\n\r\n|\r")
		else if ((w -= 8) < 0) {
			i = rnd(13)
			if (i == 11) o = "38;5;" rnd(256)
			else if (i == 12)
				o = "38;2;" rnd(256) ";" rnd(256) ";" rnd(256)
			else o = any("0|1|3|4|7|9|31|42;1|4:3|22;23;24;27;29|39;49")
			o = CSI o "m"
		} else if ((w -= 5) < 0)
			o = link("https://example.com/" rnd(1000), text())
		else if ((w -= 5) < 0)
			o = CSI between(1, 26) ";" between(1, 82) "H"
		else if ((w -= 6) < 0) o = CSI between(0, 8) one("ABCDEFG")
		else if ((w -= 4) < 0) o = CSI between(0, 2) "K"
		else if ((w -= 2) < 0) o = CSI any("0|1|2") "J"
		else if ((w -= 3) < 0) {
			t = between(1, 23); b = between(t + 1, 24)
			o = CSI t ";" b "r" CSI b ";1H"
			m = between(1, 5)
			for (i = 0; i < m; i++)
				o = o any("\n|" E "D|" E "M|" CSI "S|" CSI "T")
			o = o CSI "r"
		} else if ((w -= 3) < 0) o = CSI between(1, 5) one("@PLMX")
		else if ((w -= 2) < 0) o = E one("78")
		else if ((w -= 6) < 0) {
			m = between(1, 8)
			o = "\r" rep(CSI "1A" CSI "2K", m)
			for (i = 0; i < m; i++) o = o CSI "2K" text() "\r\n"
		} else if ((w -= 3) < 0) {
			m = between(24, 72); o = ""
			for (i = 0; i < m; i++) o = o text() "\r\n"
		} else if ((w -= 1) < 0) o = CSI "?1049h" text() CSI "?1049l"
		else o = CSI "?2026h" text() "\r\n" text() CSI "?2026l"
		ops[n] = o
	}
	ops[n++] = CSI "0m" CSI "r"
	# Four distinct cuts between operations.
	for (i = 1; i < n; i++) cut[i] = 0
	for (ncut = 0; ncut < 4; ) {
		i = between(1, n - 1)
		if (!cut[i]) { cut[i] = 1; ncut++ }
	}
	np = split(pick, pk, " ")
	for (i = 1; i <= np; i++)
		keep[pk[i]] = 1
	c = ""
	for (i = 0; i < n; i++) {
		if (i > 0 && cut[i]) { k(c); c = "" }
		if (np == 0 || (i in keep))
			c = c ops[i]
	}
	k(c)
}
BEGIN {
	E = "\033"; CSI = E "["
	ASCII = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:;-_/()[]{}<>=+*&^%$#@!?"
	WIDE = "日|本|語|漢|字|中|文|한|국|어|テ|ス|ト"
	GRIN = "\360\237\230\200"; ROCKET = "\360\237\232\200"
	CHECK = "\342\234\205"; THUMB = "\360\237\221\215\360\237\217\275"
	EMOJI = GRIN "|" ROCKET "|" CHECK "|" THUMB

	# Text and wrapping.
	start("text-plain"); k("hello\r\nworld\r\n"); k("third line\r\n")
	start("wrap-exact"); k(rep("a", 80) "next\r\n"); k(rep("b", 80)); k("c\r\n")
	start("wrap-plus-one"); k(rep("a", 81) "\r\n")
	start("wrap-long-lines"); k(lines(60, 240, 1))
	start("wrap-bottom-split")
	k(lines(30, 40, 2) rep("z", 80)); k("continued\r\nnext\r\n")
	start("wrap-then-cr"); k(rep("a", 80) "\rover\r\n")
	start("wide-chars")
	k(rep("日本語テキスト", 12) "\r\n"); k(rep("한국어", 30) "\r\n")
	start("wide-at-edge")
	k(rep("a", 79) "字tail\r\n")
	k(lines(10, 30, 17) rep("b", 79) rep("字", 5) "\r\n")
	# e, a, n, o with combining acute, diaeresis, tilde, circumflex+dot.
	start("combining")
	k(rep("e\314\201 a\314\210 n\314\203 o\314\202\314\243 ", 8) "\r\n")
	# Emoji with skin tone, ZWJ sequence, flag, variation selector.
	start("emoji")
	k(rep(GRIN " " THUMB " \360\237\221\251\342\200\215\360\237\222\273 " \
	    "\360\237\207\257\360\237\207\265 \342\235\244\357\270\217 " \
	    CHECK "\r\n", 3))
	# LF, CR, VT, FF, and NEL (U+0085).
	start("newline-variants"); k("a\nb\rc\013d\014e\r\n"); k("\302\205f\r\n")
	start("backspace-tab")
	k("abc\b\bX\tY\t\tZ\r\n"); k(CSI "3g" E "H"); k("\tq\r\n"); k(CSI "Zw\r\n")
	differ("tmux draws the gap a tab leaves as spaces or cursor movement, so the terminal no longer knows it was a tab (copying it gives spaces)")

	# Attributes.
	start("sgr-basic")
	split("1 bold 2 dim 3 italic 4 under 5 blink 7 reverse 8 hidden 9 strike 53 over", a, " ")
	o = ""
	for (i = 1; i < 18; i += 2) o = o CSI a[i] "m" a[i + 1] CSI "0m "
	k(o "\r\n")
	start("sgr-colours")
	o = ""; for (i = 0; i < 8; i++) o = o CSI "3" i "m" i
	k(o CSI "0m\r\n")
	o = ""; for (i = 0; i < 256; i += 5) o = o CSI "38;5;" i "m#"
	k(o CSI "0m\r\n")
	o = ""; for (i = 0; i < 256; i += 8) o = o CSI "38;2;" i ";" 255 - i ";" int(i / 2) "m#"
	k(o CSI "0m\r\n")
	o = ""; for (i = 16; i < 64; i++) o = o CSI "48;5;" i "m "
	k(o CSI "0m\r\n")
	start("sgr-underline-styles")
	o = ""; for (i = 1; i < 6; i++) o = o CSI "4:" i "m style" i " " CSI "0m"
	k(o "\r\n")
	k(CSI "4;58;5;196mcoloured" CSI "0m " CSI "4:3;58:2::0:128:255mcurly" CSI "0m\r\n")
	start("bce-fill")
	k(CSI "44mblue\r\n" CSI "K" CSI "5;10H" CSI "1K" CSI "J" CSI "0m\r\n")
	k(CSI "41m" lines(30, 20, 3) CSI "0m")

	# Hyperlinks.
	start("hyperlinks")
	k(link("https://example.com/a", "short") " " link("https://example.com/b", "id link", "id=x") "\r\n")
	k(link("https://example.com/wrap", rep("w", 100)) "\r\n")
	k(link("https://example.com/c", "part1") "gap" link("https://example.com/c", "part2") "\r\n")

	# Cursor movement and editing.
	start("cursor-moves")
	k(CSI "2J" CSI "5;5HA" CSI "2AB" CSI "3BC" CSI "4CD" CSI "2DE" CSI "10GF" \
	    CSI "12dG" CSI "3;70fH" CSI "99;99HI" CSI "1;1HJ\r\n")
	start("save-restore")
	k(CSI "31m" E "7" CSI "10;10H" CSI "32mgreen" E "8" "red?" CSI "0m" \
	    CSI "s" CSI "20;1Hlow" CSI "u" "back\r\n")
	start("erase-line")
	k(rep("x", 80) "\r\n" rep("y", 80) CSI "A" CSI "40G" CSI "0K" CSI "B" \
	    CSI "20G" CSI "1K" "\r\n" rep("z", 80) CSI "2K" "\r\n")
	start("erase-display")
	k(lines(20, 70, 4) CSI "10;40H" CSI "0J"); k("\r\n" CSI "5;5H" CSI "1J")
	k(CSI "2Jafter\r\n")
	start("erase-below-home"); k(lines(10, 160, 22) CSI "H" CSI "Jafter\r\n")
	start("erase-characters")
	k(rep("q", 80) CSI "1;10H" CSI "5X" CSI "1;70H" CSI "20X" "\r\n\r\n")
	start("insert-delete-characters")
	k(CSI "2J" CSI "Habcdefghij" CSI "1;3H" CSI "2@XY" CSI "1;8H" CSI "3P\r\n")
	start("insert-delete-lines")
	k(lines(20, 30, 5) CSI "5;1H" CSI "3Lins" CSI "10;1H" CSI "2M" CSI "24;1H")
	start("insert-mode"); k(CSI "4habc" CSI "1DXYZ" CSI "4l\r\n")
	start("repeat"); k("=" CSI "20b\r\n#" CSI "200b\r\n")
	start("charset")
	k(E "(0lqqqk\r\nx   x\r\nmqqqj" E "(B\r\n"); k("\016" rep("q", 10) "\017ascii\r\n")
	differ("tmux draws line-drawing characters as their UTF-8 equivalents; they look the same, but the terminal holds different characters")

	# Scrolling and regions.
	start("scroll-burst"); k(lines(300, 160, 6))
	start("scroll-region")
	k(lines(24, 30, 7) CSI "5;15r" CSI "15;1H" rep("\n", 5) rep(E "M", 3) \
	    CSI "2S" CSI "3T" E "E" CSI "r" CSI "24;1H")
	start("scroll-region-top")
	k(lines(24, 30, 8) CSI "1;12r" CSI "12;1H" rep("\n", 8) CSI "r" CSI "24;1Hend\r\n")
	start("reverse-index"); k(CSI "H" rep(E "M", 5) "top\r\n" lines(10, 20, 9))
	start("origin-mode")
	k(CSI "5;10r" CSI "?6h" CSI "1;1Horigin" CSI "20;1Hclamped" CSI "?6l" \
	    CSI "r" CSI "24;1H\r\n")
	start("autowrap-off")
	k(CSI "?7l" rep("n", 110) CSI "?7h\r\n"); k(CSI "?7l" rep("m", 80) CSI "?7hafter\r\n")
	start("clear-and-continue")
	k(lines(40, 60, 10) CSI "H" CSI "2Jcleared\r\n" lines(5, 160, 11))

	# Screens and modes.
	start("alt-screen")
	k(lines(10, 160, 12) CSI "?1049h" CSI "Hin alternate" CSI "?1049lback\r\n")
	start("alt-screen-exit-burst")
	k(lines(10, 160, 13) CSI "?1049h" CSI "Hfull screen" CSI "?1049l" lines(60, 50, 14))
	start("alt-screen-47")
	k(CSI "?47hold alt" CSI "?47l" CSI "?1047halt 1047" CSI "?1047lmain\r\n")
	start("sync-output")
	k(lines(5, 160, 15) CSI "?2026h" lines(40, 50, 16) CSI "?2026l"); k("after\r\n")
	# A progress display redrawn in place: up three rows, rewrite them.
	start("inline-repaint")
	o = "\r\n\r\n\r\n"
	for (i = 1; i < 12; i++)
		o = o CSI "3A" CSI "2Kframe " i " a\r\n" CSI "2Kframe " i " b\r\n" \
		    CSI "2K" rep("#", i * 7 % 80) "\r\n"
	k(o)
	start("title-bell"); k(E "]0;title\007\007text\r\n" E "]2;other" E "\\more\r\n")

	# Output tmux held back (an alternate screen switched on and off within
	# one read, a synchronized update) and drew again afterwards: what the
	# terminal would have done with it - lines kept in its scrollback, rows
	# no longer joined - still happens.
	start("held-clear"); k(CSI "?1049halternate" CSI "?1049lon screen" CSI "2J")
	start("held-erase-below")
	k(lines(5, 160, 18) CSI "?1049halternate" CSI "?1049l" CSI "H" CSI "J")
	start("held-region-scroll")
	k(lines(24, 30, 19) CSI "?1049halternate" CSI "?1049l" CSI "10;15r" \
	    CSI "15;1H\n\n" E "D" CSI "r" CSI "24;1H")
	start("held-repaint")
	k(rep("L", 120) CSI "?1049halternate" CSI "?1049l\r" rep(CSI "1A" CSI "2K", 3) \
	    CSI "2Kone\r\n" CSI "2Ktwo\r\n" CSI "2Kthree\r\n")
	start("sync-clear")
	k(lines(10, 160, 20) CSI "?2026hin sync\r\n" CSI "2Jafter clear" CSI "?2026l"); k("\r\n")
	start("sync-region-scroll")
	k(lines(24, 30, 21) CSI "?2026h" CSI "5;12r" CSI "12;1H" rep("\n", 4) CSI "r" \
	    CSI "24;1Hin sync" CSI "?2026l"); k("\r\n")
	# A line wrapping from the bottom row, then something other than a
	# character first on the new row: the terminal still joins them.
	start("wrap-bottom-erase-start"); k(rep("w", 110) "\r" CSI "1K\r\n")
	start("wrap-coloured-erase"); k(CSI "42m" rep("g", 110) CSI "1K" CSI "0m\r\n")
	# Erasing the row the cursor is waiting to wrap at the end of.
	start("erase-pending-twice"); k(rep("a", 80) rep("b", 80) CSI "2Kafter\r\n")
	start("erase-pending-held")
	k(rep("a", 80) CSI "2Kafter" CSI "?1049halternate" CSI "?1049l")
	start("region-coloured-scroll")
	k(rep("h", 250) CSI "42;1m\r\n" rep("i", 350) CSI "12;19r" CSI "19;1H" \
	    CSI "T\n" E "D" CSI "r" CSI "0m" CSI "24;1H")
	# Held output with wrapped lines going into the history.
	start("held-burst-wrapped")
	k(CSI "?1049halternate" CSI "?1049l" lines(40, 240, 24))
	start("sync-delete-lines")
	k(CSI "?2026h" rep("x", 100) "\r\n" rep("y", 80) CSI "?2026l" CSI "3M" \
	    CSI "?2026h" rep("z", 120) "\r\n" rep("v", 200) CSI "?2026l"); k("\r\n")
	start("clear-below-home-pending")
	k(lines(20, 70, 27) CSI "3;1HNEWTEXT" CSI "H" CSI "J")
	# Fuzz operations that differed, on their own (fuzz(seed, operations)):
	# a region scroll pushing lines into the history after coloured wrapped
	# lines; a synchronized update after a line wrapped over several rows;
	# wrapped lines after a scroll region is reset; a full row, then a clear
	# inside held output.
	start("region-push-wrap"); fuzz(4, "27 28 35")
	start("sync-after-wrap"); fuzz(16, "23 24")
	start("region-left-set"); fuzz(17, "2 6 7")
	start("held-clear-after-full-row"); fuzz(2, "25 27 28 30 33")
	# A synchronized update wrapping on from a blank row the cursor waited
	# at the end of (after deleting lines): that row is drawn again too.
	start("sync-wrap-from-blank"); fuzz(11, "20 23 25 26")
	# Output thrown away while the pane waits to be drawn again (here an
	# erase over an image) leaves no mark: a later short write does not
	# erase the rest of its row.
	start("held-erase-image")
	k(lines(10, 60, 28) CSI "20;30H" E "Pq#0;2;100;0;0#0~~@@vv@@~~@@~~$-" E "\\")
	k(CSI "20;1H" CSI "2KWXYZWXYZWXYZ"); k(CSI "20;1HOK" CSI "24;1H")
	# The rows drawn again after a synchronized update do not keep a wrap
	# into the next the program's erase ended.
	start("sync-erase-continuation")
	k(rep("s", 120) CSI "?2026h\r\n\r\n" CSI "2A" CSI "2Kshort" CSI "?2026l"); k("\r\n")
	start("sync-link-wrap")
	k(CSI "?2026h" link("https://example.com/w", rep("w", 100)) rep("\r\n", 30) CSI "?2026l"); k("\r\n")

	for (i = 0; i < 24; i++) {
		start(sprintf("fuzz-%02d", i)); fuzz(i)
	}
	close(dir "/list")
}
EOF

# Wait up to $2 tenths of a second for a command to succeed.
wait_for() {
	n=0
	until eval "$1"; do
		n=$((n + 1))
		[ $n -gt "$2" ] && return 1
		sleep 0.1
	done
	return 0
}

# Wait until both outer panes have stopped changing.
wait_quiet() {
	last=
	same=0
	n=0
	while [ $same -lt 5 ] && [ $n -lt 200 ]; do
		now=$($OUTER capturep -pet bare -S- -E- 2>/dev/null | cksum)
		now="$now $($OUTER capturep -pet tmux -S- -E- 2>/dev/null | cksum)"
		if [ "$now" = "$last" ]; then
			same=$((same + 1))
		else
			same=0
		fi
		last=$now
		n=$((n + 1))
		sleep 0.1
	done
}

# The first 16 colours are the same written 38;5;N or 3N/9N (48;5;N or
# 4N/10N), and tmux writes the short form.
colours() {
	i=0
	while [ $i -lt 8 ]; do
		printf 's/\([[;]\)38;5;%d\([;m]\)/\\13%d\\2/g\n' $i $i
		printf 's/\([[;]\)48;5;%d\([;m]\)/\\14%d\\2/g\n' $i $i
		printf 's/\([[;]\)38;5;%d\([;m]\)/\\19%d\\2/g\n' $((i + 8)) $i
		printf 's/\([[;]\)48;5;%d\([;m]\)/\\110%d\\2/g\n' $((i + 8)) $i
		i=$((i + 1))
	done >$DIR/colours.sed
}

# From the last marker on, trailing blanks and blank lines dropped. Hyperlink
# ids only group cells for hover and tmux numbers its own, so they are not
# compared. A row ending in blank cells ends in the escapes that return to
# the default for them (a cell cleared and one never written look the same),
# which are dropped with the blanks.
tidy() {
	awk '/@@render-parity@@/ { n = 0; delete l } { l[n++] = $0 }
	    END { for (i = 0; i < n; i++) print l[i] }' |
	    sed -e 's/[[:space:]]*$//' -e 's/\]8;[^;]*;/]8;;/g' \
	    -e :t -e "s/$E\\[0m\$//;tt" -e "s/$E\\[39m\$//;tt" \
	    -e "s/$E\\[49m\$//;tt" -e "s/$E\\[59m\$//;tt" \
	    -e "s/$E]8;;$E\\\\\$//;tt" -e 's/[[:space:]]*$//' |
	    sed -f $DIR/colours.sed |
	    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# Each row of history and screen with attributes and hyperlinks, captured on
# its own (fifty to a command line): capture-pane -e writes only what changes
# from one cell to the next, row after row, so a row's escapes would depend on
# the row before.
rows() {
	set -- "$1" $($OUTER display -pt "$1" '#{history_size} #{pane_height}')
	i=$((0 - $2))
	while [ $i -lt $3 ]; do
		cmd="capturep -peNt $1 -S $i -E $i"
		n=1
		while [ $((i += 1)) -lt $3 ] && [ $n -lt 50 ]; do
			cmd="$cmd \\; capturep -peNt $1 -S $i -E $i"
			n=$((n + 1))
		done
		eval "$OUTER $cmd"
	done
}

# Everything the terminal holds: history and screen with attributes and
# hyperlinks, the same with wrapped lines joined, and the cursor.
snapshot() {
	rows "$1" | tidy
	# Which rows continue the row above. Spaces are left out here: a cell
	# tmux cleared by writing a space and one the terminal cleared look the
	# same, and the rows above already compare them in place.
	echo '--- joined'
	$OUTER capturep -pJt "$1" -S- -E- | tidy | tr -d ' ' 
	# A cursor waiting to wrap after the last column shows in the last
	# column; whether it waits is up to what writes next.
	echo '--- cursor'
	$OUTER display -pt "$1" \
	    '#{cursor_x} #{pane_width} #{cursor_y} #{alternate_on}' |
	    awk '{ print ($1 >= $2 ? $2 - 1 : $1) "," $3, $4 }'
}

run_case() {
	name=$1
	case=$CASES/$name
	rm -f $DIR/go $DIR/done.*

	$OUTER new -d -s keep \; set -g history-limit 100000 \; \
	    set -g default-terminal xterm-256color \; set -g status off \; \
	    set -s clear-on-attach off || exit 1
	$INNER new -d -s inner -x 80 -y 24 \
	    "sh $DIR/write.sh $case $DIR/go $DIR/done.tmux" \; \
	    set -g status off \; set -s clear-on-attach off \; \
	    set -as terminal-features \
	    ',xterm*:hyperlinks:usstyle:RGB:strikethrough:overline' || exit 1
	if [ -n "$RENDER_PARITY_FORWARD" ]; then
		$INNER set -s forward-output $RENDER_PARITY_FORWARD || exit 1
	fi
	$OUTER new -d -s bare -x 80 -y 24 \
	    "sh $DIR/write.sh $case $DIR/go $DIR/done.bare" || exit 1
	$OUTER new -d -s tmux -x 80 -y 24 \
	    "unset TMUX; exec $INNER attach -t inner" || exit 1

	wait_for "[ -n \"\$($INNER lsc 2>/dev/null)\" ]" 50 || exit 1
	wait_quiet
	touch $DIR/go
	wait_for "[ -e $DIR/done.bare ] && [ -e $DIR/done.tmux ]" 600 || exit 1
	wait_quiet

	snapshot bare >$DIR/bare
	snapshot tmux >$DIR/tmux
	# Wait for both servers to be gone: the next case starts servers on the
	# same sockets, and one still exiting takes the new command with it.
	$INNER kill-server 2>/dev/null
	$OUTER kill-server 2>/dev/null
	wait_for "! $INNER ls >/dev/null 2>&1 && ! $OUTER ls >/dev/null 2>&1" 50

	if cmp -s $DIR/bare $DIR/tmux; then
		if [ -e "$case/differ" ]; then
			echo "$name: now the same (was expected to differ)"
		fi
		return 0
	fi
	if [ -e "$case/differ" ]; then
		echo "$name: differs as expected: $(cat "$case/differ")"
		return 0
	fi
	echo "$name: differs" >&2
	diff -u $DIR/bare $DIR/tmux | sed -n '1,40p' >&2
	return 1
}

colours
if [ -z "$RENDER_PARITY_DIR" ]; then
	mkdir $DIR/cases && LC_ALL=C awk -v dir=$DIR/cases -f $DIR/cases.awk ||
	    exit 1
fi
failed=0
for name in ${RENDER_PARITY_CASES:-$(cat $CASES/list 2>/dev/null || ls $CASES)}; do
	run_case "$name" || failed=1
done
exit $failed
