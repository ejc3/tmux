#!/bin/sh
# A pull request that fixes something is two commits: the first adds or
# changes tests only (its subject starts "regress:") and the second makes
# them pass. Check the first: at that commit at least one of its tests must
# fail, or the tests do not show what the second commit changes.
#
#   sh .github/fork/redgreen.sh BASE HEAD
#
# The tests run in a build of the first commit. If its message mentions
# -fsanitize=address (a leak, or memory used after it was freed, which an
# ordinary build does not show), the build is made with it.
set -u
BASE=$1
HEAD=$2
ONE=$(readlink -f "$(dirname "$0")/one.sh")

first=$(git rev-list --reverse "$BASE..$HEAD" | head -1)
if [ -z "$first" ] || [ "$first" = "$(git rev-parse "$HEAD")" ]; then
	echo "fewer than two commits: nothing to check"
	exit 0
fi
case "$(git log -1 --format=%s "$first")" in
regress:*) ;;
*)	echo "the first commit is not a test commit: nothing to check"
	exit 0 ;;
esac
if git diff --name-only "$first^" "$first" | grep -qv '^regress/'; then
	echo "the test commit changes more than tests:"
	git diff --name-only "$first^" "$first" | grep -v '^regress/'
	exit 1
fi
tests=$(git diff --name-only "$first^" "$first" -- 'regress/*.sh' |
    sed 's|^regress/||')
if [ -z "$tests" ]; then
	echo "the test commit changes no test"
	exit 1
fi

flags=
if git log -1 --format=%b "$first" | grep -q -e '-fsanitize=address'; then
	echo "building with -fsanitize=address"
	flags='LIBS=-lresolv LDFLAGS=-fsanitize=address,undefined'
	CFLAGS='-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined'
	export CFLAGS
fi
rm -rf ../red
git worktree add -q --detach ../red "$first" || exit 1
(cd ../red && sh autogen.sh && ./configure --enable-sixel $flags &&
    make -j"$(nproc)") >../red-build.log 2>&1 ||
    { tail -30 ../red-build.log; exit 1; }

cd ../red/regress || exit 1
mkdir -p logs
red=0
for t in $tests; do
	sh "$ONE" "$PWD/../tmux" red "$t"
	rc=$(cat "logs/$t.red.rc")
	if [ "$rc" != 0 ]; then
		red=$((red + 1))
		echo "RED $t (rc $rc): $(tail -1 "logs/$t.red.log")"
	else
		echo "passes already: $t"
	fi
done
if [ $red -eq 0 ]; then
	echo "no test of the first commit fails without the second"
	exit 1
fi
exit 0
