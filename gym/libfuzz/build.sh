#!/bin/sh
# Build tmux's libFuzzer harnesses, plus input-kgfx and tty-keys (harness/),
# with ASan and UBSan, in a worktree of the tmux fork.
#   sh gym/libfuzz/build.sh TMUX_WORKTREE
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$1"
cp "$HERE"/harness/*.c "$HERE"/harness/*.h fuzz/
git apply "$HERE"/harness/Makefile.am.patch 2>/dev/null || true
sh autogen.sh
./configure --enable-fuzzing --enable-sixel CC=clang LIBS=-lresolv \
    CFLAGS="-g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=undefined" \
    FUZZING_LIBS="-fsanitize=fuzzer,address,undefined"
make -j"$(nproc)"
make -j"$(nproc)" fuzz/input-fuzzer fuzz/cmd-parse-fuzzer fuzz/format-fuzzer \
    fuzz/style-fuzzer fuzz/input-kgfx-fuzzer fuzz/tty-keys-fuzzer
rm -rf seeds
python3 "$HERE"/seeds.py seeds
sh "$HERE"/regress-seeds.sh . seeds/regress
cp seeds/regress/* seeds/kgfx/
cp seeds/regress/* seeds/input/
for f in seeds/regress/*; do
	(printf '\001'; cat "$f"; printf '\377\377') >seeds/keys/"$(basename "$f")"
done
cat fuzz/input-fuzzer.dict >>seeds/kgfx.dict
cat fuzz/input-fuzzer.dict >>seeds/keys.dict
