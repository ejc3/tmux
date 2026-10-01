#!/bin/sh
# Run tmux's regress scripts with every tmux under valgrind memcheck.
#
#   sh gym/valgrind/run-regress.sh TMUX REGRESS-DIR OUT [JOBS] [SCRIPT...]
#
# Each script runs as .github/fork/one.sh runs it (env -i, its own HOME and
# TMUX_TMPDIR, a time limit), with TEST_TMUX a wrapper that runs tmux under
# valgrind and logs each process to OUT/vg/SCRIPT/vg.PID. Script output and
# exit status go to OUT/logs. Summarise with gym/valgrind/report.py OUT.
set -u
BIN=$(readlink -f "$1")
REGRESS=$(readlink -f "$2")
OUT=$(readlink -f "$3")
JOBS=${4:-16}
shift 3
[ $# -gt 0 ] && shift
HERE=$(dirname "$(readlink -f "$0")")
mkdir -p "$OUT/logs" "$OUT/vg" "$OUT/w"

one() {
	t=$1
	vg="$OUT/vg/$t"
	w="$OUT/w/$t"
	mkdir -p "$vg" "$w"
	cat >"$w/tmux" <<W
#!/bin/sh
exec /usr/bin/valgrind --quiet --tool=memcheck --track-origins=yes \\
    --error-exitcode=99 --leak-check=full \\
    --show-leak-kinds=definite,indirect \\
    --errors-for-leak-kinds=definite,indirect \\
    --suppressions=$HERE/tmux.supp \\
    --log-file=$vg/vg.%p $BIN "\$@"
W
	chmod +x "$w/tmux"
	d=$(mktemp -d)
	start=$(date +%s)
	(cd "$REGRESS" && env -i PATH=/usr/bin:/bin LC_CTYPE=C.UTF-8 \
	    HOME="$d" TMUX_TMPDIR="$d" SHELL=/bin/sh TEST_TMUX="$w/tmux" \
	    timeout 1800 sh "$t" >"$OUT/logs/$t.log" 2>&1)
	echo $? >"$OUT/logs/$t.rc"
	echo $(($(date +%s) - start)) >"$OUT/logs/$t.time"
	for s in "$d"/tmux-*/*; do
		[ -S "$s" ] && env -i "$BIN" -S "$s" kill-server 2>/dev/null
	done
	rm -rf "$d"
}

if [ $# -gt 0 ]; then
	tests="$*"
else
	tests=$(cd "$REGRESS" && ls *.sh)
fi
if [ "${VG_ONE:-}" ]; then
	one "$VG_ONE"
	exit
fi
for t in $tests; do echo "$t"; done |
    xargs -P "$JOBS" -I{} env VG_ONE={} sh "$0" "$BIN" "$REGRESS" "$OUT" "$JOBS"
