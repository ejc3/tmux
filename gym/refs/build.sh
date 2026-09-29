#!/bin/sh
# Build the reference engines gym/consensus.py and validate.py drive:
#   ghostty/gvt   libghostty-vt (GHOSTTY_VT: a Ghostty checkout built with
#                 zig build -Demit-lib-vt=true; needs Zig 0.16)
#   refs/lvt      libvterm (apt install libvterm-dev)
#   refs/avt-bin  alacritty_terminal (cargo)
set -e
cd "$(dirname "$0")/.."
G=${GHOSTTY_VT:-/mnt/fcvm-btrfs/ghostty-build/ghostty/zig-out}
cc -O2 -Wall -o ghostty/gvt ghostty/gvt.c -I"$G/include" -L"$G/lib" \
    -lghostty-vt -Wl,-rpath,"$G/lib"
cc -O2 -Wall -o refs/lvt refs/lvt.c -lvterm
(cd refs/avt && cargo build -q --release)
T=$(cd refs/avt && cargo metadata --format-version 1 --no-deps |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["target_directory"])')
cp "$T/release/avt" refs/avt-bin
echo "built ghostty/gvt refs/lvt refs/avt-bin"
