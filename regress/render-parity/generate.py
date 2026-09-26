#!/usr/bin/env python3
"""Generate the render-parity cases (see ../render-parity.sh).

A case is a directory of chunk files 1, 2, ... written in order with a pause
between, so tmux sends what came before a chunk before it reads the chunk. An
optional file "differ" holds the reason a case is expected to differ.

    python3 generate.py            # rewrite every case in this directory

The named cases cover one terminal feature each; the fuzz-NN cases mix them
at random from a fixed seed. Nothing here is specific to any application: the
inner process only writes the bytes. The output is committed so the test
itself needs only sh and tmux.
"""
import os, random, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
COLS, ROWS = 80, 24
E = "\033"
CSI = E + "["
OSC8 = lambda url, text, i="": "%s]8;%s;%s%s\\%s%s]8;;%s\\" % (E, i, url, E, text, E, E)

def lines(n, fmt="line %03d %s", width=None, seed=0):
    r = random.Random(seed)
    out = []
    for i in range(n):
        w = r.randint(0, width or COLS * 2)
        out.append(fmt % (i, "".join(r.choice("abcdefghij klmnop") for _ in range(w))))
    return "\r\n".join(out) + "\r\n"

def full(ch="x", n=COLS):
    return ch * n

# name: (chunks, reason it is expected to differ or None)
CASES = {
    # Text and wrapping.
    "text-plain": (["hello\r\nworld\r\n", "third line\r\n"], None),
    "wrap-exact": ([full("a") + "next\r\n", full("b"), "c\r\n"], None),
    "wrap-plus-one": ([full("a", COLS + 1) + "\r\n"], None),
    "wrap-long-lines": ([lines(60, width=COLS * 3, seed=1)], None),
    "wrap-bottom-split": ([lines(30, width=40, seed=2) + full("z"), "continued\r\nnext\r\n"], None),
    "wrap-then-cr": ([full("a") + "\rover\r\n"], None),
    "wide-chars": (["日本語テキスト" * 12 + "\r\n", "한국어" * 30 + "\r\n"], None),
    "wide-at-edge": ([full("a", COLS - 1) + "字" + "tail\r\n", lines(10, width=30, seed=17) + full("b", COLS - 1) + "字" * 5 + "\r\n"], None),
    "combining": (["é ä ñ ộ " * 8 + "\r\n"], None),
    "emoji": (["\U0001F600 \U0001F44D\U0001F3FD \U0001F469‍\U0001F4BB \U0001F1EF\U0001F1F5 ❤️ ✅\r\n" * 3], None),
    "newline-variants": (["a\nb\rc\x0bd\x0ce\r\n", "\x85f\r\n"], None),
    "backspace-tab": (["abc\b\bX\tY\t\tZ\r\n", CSI + "3g" + E + "H", "\tq\r\n", CSI + "Z" + "w\r\n"],
        "tmux draws the gap a tab leaves as spaces or cursor movement, so the terminal no longer knows it was a tab (copying it gives spaces)"),
    # Attributes.
    "sgr-basic": (["".join(CSI + "%sm%s" % (a, n) + CSI + "0m " for a, n in
        (("1", "bold"), ("2", "dim"), ("3", "italic"), ("4", "under"), ("5", "blink"),
         ("7", "reverse"), ("8", "hidden"), ("9", "strike"), ("53", "over"))) + "\r\n"], None),
    "sgr-colours": (["".join(CSI + "3%dm%d" % (i, i) for i in range(8)) + CSI + "0m\r\n",
        "".join(CSI + "38;5;%dm#" % i for i in range(0, 256, 5)) + CSI + "0m\r\n",
        "".join(CSI + "38;2;%d;%d;%dm#" % (i, 255 - i, i // 2) for i in range(0, 256, 8)) + CSI + "0m\r\n",
        "".join(CSI + "48;5;%dm " % i for i in range(16, 64)) + CSI + "0m\r\n"], None),
    "sgr-underline-styles": (["".join(CSI + "4:%dm style%d " % (i, i) + CSI + "0m" for i in range(1, 6)) + "\r\n",
        CSI + "4;58;5;196mcoloured" + CSI + "0m " + CSI + "4:3;58:2::0:128:255mcurly" + CSI + "0m\r\n"], None),
    "bce-fill": ([CSI + "44m" + "blue\r\n" + CSI + "K" + CSI + "5;10H" + CSI + "1K" + CSI + "J" + CSI + "0m\r\n",
        CSI + "41m" + lines(30, width=20, seed=3) + CSI + "0m"], None),
    # Hyperlinks.
    "hyperlinks": ([OSC8("https://example.com/a", "short") + " " + OSC8("https://example.com/b", "id link", "id=x") + "\r\n",
        OSC8("https://example.com/wrap", full("w", COLS + 20)) + "\r\n",
        OSC8("https://example.com/c", "part1") + "gap" + OSC8("https://example.com/c", "part2") + "\r\n"], None),
    # Cursor movement and editing.
    "cursor-moves": ([CSI + "2J" + CSI + "5;5HA" + CSI + "2AB" + CSI + "3BC" + CSI + "4CD" + CSI + "2DE"
        + CSI + "10GF" + CSI + "12dG" + CSI + "3;70fH" + CSI + "99;99HI" + CSI + "1;1HJ\r\n"], None),
    "save-restore": ([CSI + "31m" + E + "7" + CSI + "10;10H" + CSI + "32mgreen" + E + "8" + "red?" + CSI + "0m"
        + CSI + "s" + CSI + "20;1Hlow" + CSI + "u" + "back\r\n"], None),
    "erase-line": ([full("x") + "\r\n" + full("y") + CSI + "A" + CSI + "40G" + CSI + "0K" + CSI + "B" + CSI + "20G" + CSI + "1K"
        + "\r\n" + full("z") + CSI + "2K" + "\r\n"], None),
    "erase-display": ([lines(20, width=70, seed=4) + CSI + "10;40H" + CSI + "0J", "\r\n" + CSI + "5;5H" + CSI + "1J", CSI + "2J" + "after\r\n"], None),
    "erase-characters": ([full("q") + CSI + "1;10H" + CSI + "5X" + CSI + "1;70H" + CSI + "20X" + "\r\n\r\n"], None),
    "insert-delete-characters": ([CSI + "2J" + CSI + "Habcdefghij" + CSI + "1;3H" + CSI + "2@XY" + CSI + "1;8H" + CSI + "3P" + "\r\n"], None),
    "insert-delete-lines": ([lines(20, width=30, seed=5) + CSI + "5;1H" + CSI + "3L" + "ins" + CSI + "10;1H" + CSI + "2M" + CSI + "24;1H"], None),
    "insert-mode": ([CSI + "4h" + "abc" + CSI + "1D" + "XYZ" + CSI + "4l" + "\r\n"], None),
    "repeat": (["=" + CSI + "20b" + "\r\n" + "#" + CSI + "200b" + "\r\n"], None),
    "charset": ([E + "(0" + "lqqqk\r\nx   x\r\nmqqqj" + E + "(B" + "\r\n", "\x0e" + "q" * 10 + "\x0f" + "ascii\r\n"],
        "tmux draws line-drawing characters as their UTF-8 equivalents; they look the same, but the terminal holds different characters"),
    # Scrolling and regions.
    "scroll-burst": ([lines(300, width=COLS * 2, seed=6)], None),
    "scroll-region": ([lines(24, width=30, seed=7) + CSI + "5;15r" + CSI + "15;1H" + "\n" * 5 + E + "M" * 3 + CSI + "2S" + CSI + "3T" + E + "E" + CSI + "r" + CSI + "24;1H"], None),
    "scroll-region-top": ([lines(24, width=30, seed=8) + CSI + "1;12r" + CSI + "12;1H" + "\n" * 8 + CSI + "r" + CSI + "24;1H" + "end\r\n"], None),
    "reverse-index": ([CSI + "H" + E + "M" * 5 + "top\r\n" + lines(10, width=20, seed=9)], None),
    "origin-mode": ([CSI + "5;10r" + CSI + "?6h" + CSI + "1;1Horigin" + CSI + "20;1Hclamped" + CSI + "?6l" + CSI + "r" + CSI + "24;1H\r\n"], None),
    "autowrap-off": ([CSI + "?7l" + full("n", COLS + 30) + CSI + "?7h" + "\r\n", CSI + "?7l" + full("m", COLS) + CSI + "?7h" + "after\r\n"], None),
    "clear-and-continue": ([lines(40, width=60, seed=10) + CSI + "H" + CSI + "2J" + "cleared\r\n" + lines(5, seed=11)], None),
    # Screens and modes.
    "alt-screen": ([lines(10, seed=12) + CSI + "?1049h" + CSI + "Hin alternate" + CSI + "?1049l" + "back\r\n"], None),
    "alt-screen-exit-burst": ([lines(10, seed=13) + CSI + "?1049h" + CSI + "Hfull screen" + CSI + "?1049l" + lines(60, width=50, seed=14)], None),
    "alt-screen-47": ([CSI + "?47h" + "old alt" + CSI + "?47l" + CSI + "?1047h" + "alt 1047" + CSI + "?1047l" + "main\r\n"], None),
    "sync-output": ([lines(5, seed=15) + CSI + "?2026h" + lines(40, width=50, seed=16) + CSI + "?2026l", "after\r\n"], None),
    # A progress display redrawn in place: up three rows, rewrite them.
    "inline-repaint": (["\r\n\r\n\r\n" + "".join(CSI + "3A" + CSI + "2K" + "frame %d a\r\n" % f + CSI + "2K" + "frame %d b\r\n" % f
        + CSI + "2K" + full("#", f * 7 % COLS) + "\r\n" for f in range(1, 12))], None),
    # Output tmux held back (an alternate screen switched on and off within
    # one read, a synchronized update) and drew again afterwards: what the
    # terminal would have done with it - lines kept in its scrollback, rows no
    # longer joined - still happens.
    "held-clear": ([CSI + "?1049h" + "alternate" + CSI + "?1049l" + "on screen" + CSI + "2J"], None),
    "held-erase-below": ([lines(5, seed=18) + CSI + "?1049h" + "alternate" + CSI + "?1049l" + CSI + "H" + CSI + "J"], None),
    "held-region-scroll": ([lines(24, width=30, seed=19) + CSI + "?1049h" + "alternate" + CSI + "?1049l"
        + CSI + "10;15r" + CSI + "15;1H" + "\n\n" + E + "D" + CSI + "r" + CSI + "24;1H"], None),
    "held-repaint": ([full("L", COLS + 40) + CSI + "?1049h" + "alternate" + CSI + "?1049l" + "\r" + (CSI + "1A" + CSI + "2K") * 3
        + CSI + "2K" + "one\r\n" + CSI + "2K" + "two\r\n" + CSI + "2K" + "three\r\n"], None),
    "sync-clear": ([lines(10, seed=20) + CSI + "?2026h" + "in sync\r\n" + CSI + "2J" + "after clear" + CSI + "?2026l", "\r\n"], None),
    "sync-region-scroll": ([lines(24, width=30, seed=21) + CSI + "?2026h" + CSI + "5;12r" + CSI + "12;1H" + "\n" * 4
        + CSI + "r" + CSI + "24;1H" + "in sync" + CSI + "?2026l", "\r\n"], None),
    "sync-link-wrap": ([CSI + "?2026h" + OSC8("https://example.com/w", full("w", COLS + 20)) + "\r\n" * 30 + CSI + "?2026l", "\r\n"], None),
    "erase-below-home": ([lines(10, seed=22) + CSI + "H" + CSI + "J" + "after\r\n"], None),
    "title-bell": ([E + "]0;title" + "\x07" + "\x07" + "text\r\n" + E + "]2;other" + E + "\\" + "more\r\n"], None),
}

# Fuzz cases that still differ, with what is known (open: not yet fixed).
FUZZ_DIFFER = {}

def fuzz(seed, n=40):
    """Random mix of the above, generic terminal output only."""
    r = random.Random(seed)
    ascii_ = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:;-_/()[]{}<>=+*&^%$#@!?"
    def text():
        k = r.choice(["ascii", "ascii", "wide", "emoji", "exact", "long"])
        if k == "ascii": return "".join(r.choice(ascii_) for _ in range(r.randint(1, 40)))
        if k == "wide": return "".join(r.choice("日本語漢字中文한국어テスト") for _ in range(r.randint(1, 20)))
        if k == "emoji": return "".join(r.choice(["\U0001F600", "\U0001F680", "✅", "\U0001F44D\U0001F3FD"]) for _ in range(r.randint(1, 6)))
        if k == "exact": return "".join(r.choice(ascii_[:62]) for _ in range(COLS))
        return "".join(r.choice(ascii_) for _ in range(r.randint(COLS, COLS * 4)))
    ops = []
    for _ in range(n):
        k = r.choices(["text", "nl", "sgr", "link", "cup", "move", "el", "ed", "region", "edit", "save", "repaint", "burst", "alt", "sync"],
                      weights=[30, 18, 8, 5, 5, 6, 4, 2, 3, 3, 2, 6, 3, 1, 2])[0]
        if k == "text": ops.append(text())
        elif k == "nl": ops.append(r.choice(["\r\n", "\n", "\r\n\r\n", "\r"]))
        elif k == "sgr": ops.append(CSI + r.choice(["0", "1", "3", "4", "7", "9", "31", "42;1", "38;5;%d" % r.randint(0, 255),
            "38;2;%d;%d;%d" % (r.randint(0, 255), r.randint(0, 255), r.randint(0, 255)), "4:3", "22;23;24;27;29", "39;49"]) + "m")
        elif k == "link": ops.append(OSC8("https://example.com/%d" % r.randint(0, 999), text()))
        elif k == "cup": ops.append(CSI + "%d;%dH" % (r.randint(1, ROWS + 2), r.randint(1, COLS + 2)))
        elif k == "move": ops.append(CSI + "%d%s" % (r.randint(0, 8), r.choice("ABCDEFG")))
        elif k == "el": ops.append(CSI + "%dK" % r.randint(0, 2))
        elif k == "ed": ops.append(CSI + "%dJ" % r.choice([0, 1, 2]))
        elif k == "region":
            t = r.randint(1, ROWS - 1); b = r.randint(t + 1, ROWS)
            ops.append(CSI + "%d;%dr" % (t, b) + CSI + "%d;1H" % b + "".join(r.choice(["\n", E + "D", E + "M", CSI + "S", CSI + "T"]) for _ in range(r.randint(1, 5))) + CSI + "r")
        elif k == "edit": ops.append(CSI + "%d%s" % (r.randint(1, 5), r.choice("@PLMX")))
        elif k == "save": ops.append(r.choice([E + "7", E + "8"]))
        elif k == "repaint":
            m = r.randint(1, 8)
            ops.append("\r" + (CSI + "1A" + CSI + "2K") * m + "".join(CSI + "2K" + text() + "\r\n" for _ in range(m)))
        elif k == "burst": ops.append("".join(text() + "\r\n" for _ in range(r.randint(ROWS, ROWS * 3))))
        elif k == "alt": ops.append(CSI + "?1049h" + text() + CSI + "?1049l")
        elif k == "sync": ops.append(CSI + "?2026h" + text() + "\r\n" + text() + CSI + "?2026l")
    ops.append(CSI + "0m" + CSI + "r")
    global LAST_OPS
    LAST_OPS = ops
    # About five chunks, split between operations.
    cuts = sorted(r.sample(range(1, len(ops)), 4))
    return ["".join(ops[a:b]) for a, b in zip([0] + cuts, cuts + [len(ops)])]

def write(name, chunks, differ):
    d = os.path.join(HERE, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for i, c in enumerate(chunks, 1):
        with open(os.path.join(d, str(i)), "wb") as f:
            f.write(c.encode("utf-8"))
    if differ:
        with open(os.path.join(d, "differ"), "w") as f:
            f.write(differ + "\n")

if __name__ == "__main__":
    for name, (chunks, differ) in CASES.items():
        write(name, chunks, differ)
    for seed in range(24):
        write("fuzz-%02d" % seed, fuzz(seed), FUZZ_DIFFER.get(seed))
    print("%d cases" % (len(CASES) + 24))
