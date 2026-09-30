#!/bin/sh
# Set up every judge the gym uses, from nothing, in $JUDGES (default
# /mnt/fcvm-btrfs/term-judges; that disk is wiped when the host stops, so
# run this again after). Idempotent: what is there is kept.
#
#   sh gym/refs/setup-judges.sh
#
# kitty and WezTerm are their nightly builds (the target the protocol matrix
# measures against); Ghostty's libghostty-vt is built from a pinned commit
# with a pinned Zig. What was fetched is written to $JUDGES/VERSIONS.
# System packages (Debian/Ubuntu): libvterm-dev xvfb xterm python3-gi
# gir1.2-vte-2.91 gir1.2-gtk-3.0 cargo curl xz-utils git.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
JUDGES=${JUDGES:-/mnt/fcvm-btrfs/term-judges}
GHOSTTY_COMMIT=0538f7535be0cbca6bbe54e6fde654d5c628f1f2
ZIG_VERSION=0.16.0
case $(uname -m) in
aarch64|arm64) ARCH=arm64; ZARCH=aarch64; WARCH=.arm64 ;;
x86_64|amd64) ARCH=x86_64; ZARCH=x86_64; WARCH= ;;
*) echo "unsupported machine $(uname -m)" >&2; exit 1 ;;
esac
. /etc/os-release
mkdir -p "$JUDGES/tmp"
cd "$JUDGES"
: >VERSIONS.new

# kitty nightly.
if [ ! -x kitty-nightly/bin/kitty ]; then
	curl -fsSL -o kitty-nightly.txz \
	    "https://github.com/kovidgoyal/kitty/releases/download/nightly/kitty-nightly-$ARCH.txz"
	rm -rf kitty-nightly && mkdir kitty-nightly
	tar -xJf kitty-nightly.txz -C kitty-nightly
fi
ln -sfn kitty-nightly kitty
echo "kitty: $(./kitty/bin/kitty --version) (nightly, $(date -r kitty-nightly.txz +%F 2>/dev/null))" >>VERSIONS.new

# WezTerm nightly, unpacked without installing.
if [ ! -x wezterm/usr/bin/wezterm-mux-server ]; then
	curl -fsSL -o wezterm.deb \
	    "https://github.com/wezterm/wezterm/releases/download/nightly/wezterm-nightly.Ubuntu$VERSION_ID$WARCH.deb"
	rm -rf wezterm && mkdir wezterm && dpkg -x wezterm.deb wezterm
fi
echo "wezterm: $(./wezterm/usr/bin/wezterm --version)" >>VERSIONS.new

# libghostty-vt at a pinned commit.
G=${GHOSTTY_BUILD:-$JUDGES/ghostty-build}
mkdir -p "$G"
if [ ! -x "$G/zig-$ZARCH-linux-$ZIG_VERSION/zig" ]; then
	curl -fsSL -o "$G/zig.tar.xz" \
	    "https://ziglang.org/download/$ZIG_VERSION/zig-$ZARCH-linux-$ZIG_VERSION.tar.xz"
	tar -xJf "$G/zig.tar.xz" -C "$G"
fi
if [ ! -d "$G/ghostty/.git" ]; then
	git clone -q https://github.com/ghostty-org/ghostty "$G/ghostty"
fi
if [ "$(git -C "$G/ghostty" rev-parse HEAD)" != "$GHOSTTY_COMMIT" ] ||
    [ ! -e "$G/ghostty/zig-out/lib/libghostty-vt.so" ]; then
	git -C "$G/ghostty" fetch -q origin
	git -C "$G/ghostty" checkout -q "$GHOSTTY_COMMIT"
	(cd "$G/ghostty" && "$G/zig-$ZARCH-linux-$ZIG_VERSION/zig" build \
	    -Demit-lib-vt=true -Doptimize=ReleaseFast >"$G/build-vt.log" 2>&1)
fi
echo "ghostty: libghostty-vt $GHOSTTY_COMMIT, zig $ZIG_VERSION" >>VERSIONS.new

# gvt, lvt and avt (refs/build.sh).
GHOSTTY_VT="$G/ghostty/zig-out" sh "$HERE/build.sh"
echo "libvterm: $(pkg-config --modversion vterm 2>/dev/null || echo system)" >>VERSIONS.new
echo "alacritty_terminal: $(sed -n 's/^alacritty_terminal = "\(.*\)"/\1/p' "$HERE/avt/Cargo.toml")" >>VERSIONS.new
echo "xterm: $(xterm -v 2>/dev/null || echo missing)" >>VERSIONS.new
mv VERSIONS.new VERSIONS
cat VERSIONS
