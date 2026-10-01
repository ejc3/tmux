#!/bin/sh
# The blind-spot map: build tmux with --coverage, run its regress suite (each
# script with its own TMUX_TMPDIR, as .github/fork/regress.sh does) and the
# protocol fuzzers for a while, then list the lines BASE..COMMIT added that
# never ran, by file and function.
#
#   sh gym/coverage.sh TMUX_REPO COMMIT BASE [FUZZ_MINUTES] [OUT_DIR]
#
# e.g. sh gym/coverage.sh ~/src/tmux-scroll-native-v4 87c42559 3c7b12f6^ 5
# The build goes in OUT_DIR (default /tmp/tmux-coverage-COMMIT) and the map
# in OUT_DIR/map.txt and map.json.
set -eu
REPO=$(readlink -f "$1")
COMMIT=$2
BASE=$3
MINUTES=${4:-5}
OUT=${5:-/tmp/tmux-coverage-$COMMIT}
GYM=$(dirname "$(readlink -f "$0")")
unset TMUX

rm -rf "$OUT"
git -C "$REPO" worktree add --detach "$OUT" "$COMMIT" >/dev/null
cd "$OUT"
# LIBS=-lresolv: configure may not find b64_ntop needs it under other flags.
(sh autogen.sh && ./configure --enable-sixel LIBS=-lresolv \
    CFLAGS="-O0 -g --coverage" LDFLAGS="--coverage" &&
    make -j"$(getconf _NPROCESSORS_ONLN)") >build.log 2>&1 ||
    { tail -30 build.log; exit 1; }

# The regress suite, each script apart; the binary is its own base (a script
# that fails is only run again).
BASE_COMMIT=$COMMIT sh .github/fork/regress.sh ./tmux ./tmux >regress.log 2>&1 ||
    true
grep -c '^PASS' regress.log | sed 's/^/regress scripts passed: /'
grep -E '^(FAIL|FLAKY|SAME)' regress.log || true

# The fuzzers, for a while.
python3 -W ignore "$GYM/fuzz_proto.py" --tmux ./tmux --seeds 1-16 \
    --steps 200 --minutes "$MINUTES" --out fuzz-proto >fuzz.log 2>&1 || true
tail -3 fuzz.log

python3 "$GYM/coverage_map.py" . "$BASE" "$COMMIT" --json map.json | tee map.txt
