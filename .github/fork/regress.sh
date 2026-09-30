#!/bin/sh
# Run every regress script against BRANCH (a tmux binary), in parallel, each
# with its own TMUX_TMPDIR so their -Ltest servers are apart. A script that
# fails is run again alone, then against BASE (upstream's tmux at the merge
# base); it counts only if it fails alone and passes on BASE, or is new.
# Logs in regress/logs.
#
#   BASE_COMMIT=<commit> sh .github/fork/regress.sh BRANCH BASE
set -u
BRANCH=$(readlink -f "$1")
BASE=$(readlink -f "$2")
ONE=$(readlink -f "$(dirname "$0")/one.sh")
cd "$(dirname "$0")/../../regress" || exit 1
mkdir -p logs
rm -f logs/*.log logs/*.rc
ls *.sh | xargs -P "$(getconf _NPROCESSORS_ONLN)" -I{} \
    sh "$ONE" "$BRANCH" branch {}
bad=0
for t in *.sh; do
	rc=$(cat "logs/$t.branch.rc")
	if [ "$rc" = 0 ]; then
		echo "PASS $t"
		continue
	fi
	# Timing under load: run it again alone.
	sh "$ONE" "$BRANCH" alone "$t"
	if [ "$(cat "logs/$t.alone.rc")" = 0 ]; then
		echo "FLAKY $t (fails in parallel, passes alone)"
		continue
	fi
	rc=$(cat "logs/$t.alone.rc")
	if ! git cat-file -e "${BASE_COMMIT}:regress/$t" 2>/dev/null; then
		echo "FAIL $t (new, rc $rc)"
		bad=1
		continue
	fi
	sh "$ONE" "$BASE" base "$t"
	if [ "$(cat "logs/$t.base.rc")" = 0 ]; then
		echo "FAIL $t (passes on upstream, rc $rc)"
		bad=1
	else
		echo "SAME $t (fails on upstream too)"
	fi
done
echo
echo "slowest (seconds, in parallel):"
for t in *.sh; do echo "$(cat "logs/$t.branch.time") $t"; done | sort -rn | head -10
exit $bad
