#!/usr/bin/env python3
"""Fuzz the protocols the scroll-native branch adds, from both sides.

The pane side writes sequences from a grammar per protocol (kitty keyboard,
kitty graphics and its placeholders, OSC 66, OSC 22, OSC 99, OSC 9 and 777,
the private modes and resets they touch), with boundary numbers, random splits
and lifecycle commands (resize, detach, suspend, respawn, kill, split, copy
mode, capture) between them. The terminal side is a fake terminal on a pty,
attached as a client, that answers tmux's queries as kitty would (or late, or
not at all) and writes kitty key reports, pixel mouse reports, OSC 99 and
APC G answers, DECRPM answers and garbage.

After each step the server must answer, the pane's cursor must be inside the
pane and no sanitizer report may appear. Build tmux with
-fsanitize=address,undefined to catch memory errors; any build works.

    python3 gym/fuzz_proto.py --tmux PATH [--base PATH] [--seeds 1-8]
        [--steps N] [--minutes M] [--jobs J] [--out DIR] [--skip TEXT]
    python3 gym/fuzz_proto.py --tmux PATH --replay DIR/fail-SEED.json
    python3 gym/fuzz_proto.py --tmux PATH --shrink DIR/fail-SEED.json

A failure is saved as fail-SEED.json (the steps run, as data) with the
sanitizer report beside it; --shrink cuts it to the fewest steps (and the
fewest tokens in each) that fail the same way.
"""

import argparse
import base64
import fcntl
import glob
import json
import multiprocessing
import os
import random
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import zlib

ESC = b"\x1b"
ST = b"\x1b\\"
BEL = b"\x07"

BOUND = [0, 1, 2, 3, 7, 8, 16, 31, 32, 255, 256, 4095, 4096, 65535, 65536,
         2 ** 24 - 1, 2 ** 24, 2 ** 31 - 1, 2 ** 31, 2 ** 32 - 1, 2 ** 32,
         99999999999]

# kitty's rowcolumn-diacritics, the start of the table (as tmux has it).
DIACRITICS = [0x305, 0x30d, 0x30e, 0x310, 0x312, 0x33d, 0x33e, 0x33f, 0x346,
              0x34a, 0x34b, 0x34c, 0x350, 0x351, 0x352, 0x357, 0x35b, 0x363,
              0x364, 0x365, 0x366, 0x367, 0x368, 0x369, 0x36a, 0x36b, 0x36c,
              0x36d, 0x36e, 0x36f, 0x483, 0x484, 0x485, 0x486, 0x487]

POINTERS = [b"default", b"text", b"pointer", b"crosshair", b"wait", b"help",
            b"move", b"grab", b"not-allowed", b"e-resize", b"nwse-resize",
            b"zoom-in", b"", b"x" * 300, b"__current__", b"__default__",
            b"__grabbed__", b"bogus"]

TEXTS = ["a", "ab", "xyz", "\u4e2d", "\U0001f600", "\U0001f44d\U0001f3fd",
         "\U0001f468\u200d\U0001f469\u200d\U0001f467", "e\u0301", "\u0301",
         "1\ufe0f\u20e3", "\u0915\u094d\u0937", "\u200b", "\t", " ",
         "\U0010eeee", "\U0010eeee\u0305", "x" * 40, "\u4e2d" * 20]

KEYS = ["a", "A", "Enter", "Escape", "BSpace", "Tab", "BTab", "Space", "Up",
        "Down", "Left", "Right", "Home", "End", "PPage", "NPage", "IC", "DC",
        "F1", "F2", "F3", "F4", "F5", "F12", "C-a", "C-Escape", "C-BSpace",
        "M-a", "M-Up", "S-F3", "C-F3", "C-S-Left", "M-C-x", "C-Enter",
        "S-Enter", "C-Tab", "C-i", "C-m", "C-[", "C-@", "KP0", "KP*",
        "KPEnter", "C-KP5", "\u00e9", "\u4e2d", "C-\u00e9", "M-\u4e2d", "~",
        "S-Space", "C-Space", "C-S-a"]


def b64(data):
    return base64.b64encode(data)


class Gen:
    """Sequences for each protocol, from a seeded random."""

    def __init__(self, rng, files):
        self.r = rng
        self.files = files

    def num(self):
        r = self.r.random()
        if r < 0.5:
            return self.r.randint(0, 20)
        if r < 0.85:
            return self.r.choice(BOUND)
        return self.r.choice([-1, -2 ** 31, self.r.randint(-100, 100)])

    def numb(self):
        return str(self.num()).encode()

    def pick(self, *xs):
        return self.r.choice(xs)

    def text(self):
        if self.r.random() < 0.15:
            return bytes(self.r.randint(0x80, 0xff)
                         for _ in range(self.r.randint(1, 6)))
        if self.r.random() < 0.1:
            # Truncated UTF-8 at the end.
            t = self.r.choice(TEXTS).encode()
            return t + self.r.choice([b"\xf0", b"\xf0\x9f", b"\xe4\xb8",
                                      b"\xc3"])
        return "".join(self.r.choice(TEXTS)
                       for _ in range(self.r.randint(1, 4))).encode()

    def term(self):
        return self.pick(BEL, ST, ST, b"", b"\x18", b"\x9c")

    # kitty keyboard.
    def kkeys(self):
        k = self.r.randint(0, 4)
        if k == 0:
            return b"\x1b[>" + self.numb() + b"u"
        if k == 1:
            return b"\x1b[<" + self.pick(b"", self.numb()) + b"u"
        if k == 2:
            return b"\x1b[=" + self.numb() + b";" + self.numb() + b"u"
        if k == 3:
            return b"\x1b[?u"
        return b"\x1b[>" + self.numb() + b";" + self.numb() + b"u"

    # kitty graphics.
    def gkeys(self):
        a = self.pick(b"t", b"T", b"p", b"d", b"q", b"f", b"a", b"c", b"")
        keys = {}
        if a:
            keys[b"a"] = a
        if self.r.random() < 0.7:
            keys[b"i"] = self.numb()
        if self.r.random() < 0.2:
            keys[b"I"] = self.numb()
        if self.r.random() < 0.3:
            keys[b"p"] = self.numb()
        if self.r.random() < 0.4:
            keys[b"U"] = self.pick(b"0", b"1", self.numb())
        if self.r.random() < 0.5:
            keys[b"q"] = self.pick(b"0", b"1", b"2", self.numb())
        if a == b"d" or self.r.random() < 0.1:
            keys[b"d"] = self.r.choice(list(b"aAiIpPnNcCqQrRxXyYzZfF") +
                                       [ord("?")]).to_bytes(1, "big")
        for k in b"sSvVxyXYwhcrzCHPQOofmtgN":
            if self.r.random() < 0.08:
                keys[bytes([k])] = self.numb()
        if self.r.random() < 0.03:
            # More keys than any command has.
            for k in b"ABDEFGJKLMRWZbejklnuw0123456789":
                keys[bytes([k])] = b"1"
        return keys

    def gcmd(self, keys, payload=b""):
        body = b",".join(k + b"=" + v for k, v in keys.items())
        if self.r.random() < 0.05:
            body += b"," + self.pick(b"=", b"zz=1", b",,", b"a", b"=1",
                                     b"a=" + b"x" * 200)
        return b"\x1b_G" + body + (b";" + payload if payload or
                                   self.r.random() < 0.5 else b"") + \
            self.pick(ST, ST, ST, BEL, b"")

    def png(self, w, h):
        raw = b"".join(b"\x00" + bytes(self.r.randint(0, 255)
                                        for _ in range(w * 4))
                       for _ in range(h))

        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + \
                struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + \
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

    def image_data(self, keys):
        w = self.r.choice([1, 2, 3, 8, 16])
        h = self.r.choice([1, 2, 3, 8, 16])
        f = self.r.choice([b"24", b"32", b"100", b"32", b"7"])
        keys[b"f"] = f
        if f == b"100":
            data = self.png(w, h)
        else:
            keys[b"s"] = str(w).encode()
            keys[b"v"] = str(h).encode()
            data = bytes(self.r.randint(0, 255)
                         for _ in range(w * h * (3 if f == b"24" else 4)))
            if self.r.random() < 0.2:
                data = data[:self.r.randint(0, len(data))]
        if self.r.random() < 0.2:
            keys[b"o"] = b"z"
            data = zlib.compress(data) if self.r.random() < 0.8 else data
        return data

    def graphics(self):
        keys = self.gkeys()
        k = self.r.random()
        out = b""
        if keys.get(b"a") in (b"t", b"T", b"f", None) and k < 0.6:
            data = self.image_data(keys)
            medium = self.pick(b"d", b"d", b"d", b"f", b"t", b"s")
            if medium != b"d":
                keys[b"t"] = medium
                name = self.files.medium(self.r, medium, data)
                payload = b64(name.encode())
                if self.r.random() < 0.3:
                    keys[b"O"] = self.numb()
                if self.r.random() < 0.3:
                    keys[b"S"] = self.numb()
                return self.gcmd(keys, payload)
            payload = b64(data)
            if self.r.random() < 0.1:
                payload = self.pick(b"!!!!", b"AAA", b"A", b"====",
                                    payload[:-1], b"\x00\xff")
            if self.r.random() < 0.35 and len(payload) > 4:
                # Chunked: m=1 for every chunk but the last.
                n = self.r.randint(1, max(1, len(payload) // 4))
                parts = [payload[i:i + n] for i in range(0, len(payload), n)]
                first = dict(keys)
                first[b"m"] = b"1"
                out = self.gcmd(first, parts[0])
                for i, part in enumerate(parts[1:]):
                    last = i == len(parts) - 2
                    if self.r.random() < 0.05:
                        out += self.gcmd(self.gkeys(), b"")
                        continue
                    if self.r.random() < 0.1 and not last:
                        break
                    out += b"\x1b_Gm=" + (b"0" if last else b"1") + b";" + \
                        part + ST
                return out
            return self.gcmd(keys, payload)
        if keys.get(b"a") == b"f" and self.r.random() < 0.7:
            data = self.image_data(keys)
            return self.gcmd(keys, b64(data))
        return self.gcmd(keys)

    def placeholder(self):
        out = b""
        if self.r.random() < 0.8:
            if self.r.random() < 0.1:
                out += b"\x1b[%dm" % self.r.choice([30, 31, 37, 39, 90, 91,
                                                    97])
            elif self.r.random() < 0.5:
                out += b"\x1b[38;5;" + self.numb() + b"m"
            else:
                out += b"\x1b[38;2;%d;%d;%dm" % (self.r.randint(0, 255),
                                                self.r.randint(0, 255),
                                                self.r.randint(0, 255))
        if self.r.random() < 0.4:
            out += b"\x1b[58;2;%d;%d;%dm" % (self.r.randint(0, 255),
                                            self.r.randint(0, 255),
                                            self.r.randint(0, 255))
        for _ in range(self.r.randint(1, 6)):
            out += "\U0010eeee".encode()
            for _ in range(self.r.choice([0, 1, 2, 3, 3, 4])):
                if self.r.random() < 0.9:
                    out += chr(self.r.choice(DIACRITICS)).encode()
                else:
                    out += chr(self.r.choice([0x301, 0x200d, 0xfe0f,
                                              0x10eeee])).encode()
        if self.r.random() < 0.5:
            out += b"\x1b[m"
        return out

    # OSC 66.
    def osc66(self):
        meta = []
        for k in b"swnhdv":
            if self.r.random() < 0.4:
                meta.append(bytes([k]) + b"=" + self.numb())
        if self.r.random() < 0.1:
            meta.append(self.pick(b"x", b"=", b"w", b"w=", b"zz=9"))
        text = self.text()
        if self.r.random() < 0.05:
            text = text * self.r.randint(10, 200)
        return b"\x1b]66;" + b":".join(meta) + b";" + text + self.term()

    # OSC 22.
    def osc22(self):
        names = b",".join(self.r.choice(POINTERS)
                          for _ in range(self.r.randint(1, 4)))
        op = self.pick(b">", b"<", b"=", b"?", b"", b">", b"<")
        if op == b"<":
            names = self.pick(b"", names)
        return b"\x1b]22;" + op + names + self.term()

    # OSC 99.
    def osc99(self):
        meta = []
        if self.r.random() < 0.7:
            meta.append(b"i=" + self.pick(b"1", b"x", b"t0_1", b"t0.1",
                                          self.numb(), b"", b"a" * 300))
        for k, vals in ((b"d", [b"0", b"1"]), (b"p", [b"title", b"body", b"?",
                        b"alive", b"close", b"icon", b"buttons", b"x"]),
                        (b"a", [b"focus", b"report", b"-focus,report", b""]),
                        (b"o", [b"always", b"unfocused", b"invisible"]),
                        (b"u", [b"0", b"1", b"2", b"9"]),
                        (b"c", [b"0", b"1"]), (b"e", [b"0", b"1"]),
                        (b"w", [b"-1", b"0", b"1000"]),
                        (b"f", [b"", b"YQ=="]), (b"t", [b"", b"YQ=="]),
                        (b"g", [b"x"]), (b"s", [b"silent", b"x"]),
                        (b"n", [b"YQ==", b"x"])):
            if self.r.random() < 0.25:
                meta.append(k + b"=" + self.r.choice(vals))
        if self.r.random() < 0.05:
            meta.append(self.pick(b"=", b"p", b"p=?;", b";;", b":"))
        payload = self.pick(b"", b"hello", b"p=?", b"a;b", b"x" * 3000,
                            self.text(), b"t0_1,t1_2,t0.3")
        return b"\x1b]99;" + b":".join(meta) + b";" + payload + self.term()

    def osc9(self):
        if self.r.random() < 0.3:
            return b"\x1b]777;notify;" + self.text() + b";" + self.text() + \
                self.term()
        sub = self.pick(b"", b"1;", b"2;", b"3;", b"4;", b"4;1;50",
                        b"4;" + self.numb() + b";" + self.numb(), b"9;/tmp",
                        b"9;", b"10;", b"11;", b"12;", self.numb() + b";")
        return b"\x1b]9;" + sub + self.pick(b"", self.text()) + self.term()

    def modes(self):
        k = self.r.randint(0, 11)
        if k == 0:
            m = self.pick(b"1016", b"2048", b"2027", b"2026", b"1049", b"47",
                          b"1047", b"1000", b"1002", b"1003", b"1006", b"7",
                          b"25", b"1004", b"2004", b"6", b"69", b"12", b"5",
                          b"1007", b"1005", b"1015", b"2031")
            return b"\x1b[?" + m + self.pick(b"h", b"l", b"$p")
        if k == 1:
            return b"\x1b[4" + self.pick(b"h", b"l")
        if k == 2:
            return b"\x1b[!p"
        if k == 3:
            return b"\x1bc"
        if k == 4:
            return b"\x1b[" + self.numb() + b";" + self.numb() + b"r"
        if k == 5:
            return b"\x1b[" + self.numb() + b";" + self.numb() + b"H"
        if k == 6:
            return b"\x1b[" + self.numb() + self.pick(b"s", b"u", b"L", b"M",
                                                      b"@", b"P", b"X", b"K",
                                                      b"J", b"S", b"T", b"b")
        if k == 7:
            return b"\x1b[" + self.numb() + b";" + self.numb() + b"s"
        if k == 8:
            return self.pick(b"\n", b"\r\n", b"\b", b"\t", b"\x1bD", b"\x1bM",
                             b"\x1bE", b"\x1b7", b"\x1b8", b"\x1b#8")
        if k == 9:
            return b"\x1b[" + self.pick(b"14", b"16", b"18", b"22;0", b"23;0",
                                        b"8;" + self.numb() + b";" +
                                        self.numb()) + b"t"
        if k == 10:
            return b"\x1b[" + self.pick(b"c", b">c", b">q", b"6n", b"?996n",
                                        b"5n", b"?6n")
        return b"\x1b[?" + self.numb() + b"h"

    def text_run(self):
        return self.text() * self.r.randint(1, 30)

    def pane_bytes(self):
        out = b""
        for _ in range(self.r.randint(1, 6)):
            k = self.r.random()
            if k < 0.20:
                out += self.graphics()
            elif k < 0.32:
                out += self.placeholder()
            elif k < 0.44:
                out += self.osc66()
            elif k < 0.52:
                out += self.osc22()
            elif k < 0.62:
                out += self.osc99()
            elif k < 0.66:
                out += self.osc9()
            elif k < 0.74:
                out += self.kkeys()
            elif k < 0.88:
                out += self.modes()
            elif k < 0.97:
                out += self.text_run()
            else:
                out += bytes(self.r.randint(0, 255)
                             for _ in range(self.r.randint(1, 16)))
        return out

    # The terminal side.
    def term_bytes(self):
        k = self.r.randint(0, 9)
        if k <= 2:
            # A kitty key report.
            code = self.pick(b"97", b"13", b"27", b"9", b"127", b"57376",
                             b"57398", b"57399", b"57441", b"1", b"2", b"3",
                             b"15", b"0", self.numb())
            fields = code
            if self.r.random() < 0.4:
                fields += b":" + self.numb()
                if self.r.random() < 0.5:
                    fields += b":" + self.numb()
            if self.r.random() < 0.7:
                fields += b";" + self.numb()
                if self.r.random() < 0.4:
                    fields += b":" + self.pick(b"1", b"2", b"3", self.numb())
            if self.r.random() < 0.3:
                fields += b";" + b":".join(self.numb()
                                           for _ in range(self.r.randint(1, 3)))
            final = self.pick(b"u", b"u", b"~", b"A", b"B", b"C", b"D", b"H",
                              b"F", b"P", b"Q", b"S", b"E")
            if final != b"u" and self.r.random() < 0.5:
                fields = self.pick(b"1", b"13", b"") + b";" + self.numb()
            return b"\x1b[" + fields + final
        if k <= 4:
            # SGR mouse, in cells or pixels.
            return b"\x1b[<" + self.numb() + b";" + self.numb() + b";" + \
                self.numb() + self.pick(b"M", b"m")
        if k == 5:
            ident = self.pick(b"t0_1", b"t%d_%d" % (self.r.randint(0, 5),
                                                    self.r.randint(0, 5)),
                              b"t0.0", b"t0.%x.%d" % (self.r.randint(0, 2 ** 32),
                                                      self.r.randint(0, 9)),
                              b"0", b"x", b"", b"t", b"t_", b"t99999999999_1")
            meta = b"i=" + ident
            if self.r.random() < 0.6:
                meta += b":p=" + self.pick(b"?", b"alive", b"close", b"x")
            payload = self.pick(b"", b"a=focus,report:o=always",
                                b"t0_1,t0_2,t1_x", b"t0.0", b"x")
            return b"\x1b]99;" + meta + b";" + payload + self.pick(ST, BEL)
        if k == 6:
            return b"\x1b_Gi=" + self.numb() + self.pick(b"", b",p=" +
                                                         self.numb()) + b";" + \
                self.pick(b"OK", b"ENOENT:x", b"EINVAL", b"") + self.pick(ST,
                                                                         BEL)
        if k == 7:
            return b"\x1b[?" + self.numb() + b";" + self.numb() + b"$y"
        if k == 8:
            seq = self.pick(b"\x1b[", b"\x1b]", b"\x1b_G", b"\x1bP", b"\x1b[<",
                            b"\x1b[?", b"\x1b]99;", b"\x1b[>")
            return seq + bytes(self.r.randint(0x20, 0x7e)
                               for _ in range(self.r.randint(0, 8)))
        return bytes(self.r.randint(0, 255)
                     for _ in range(self.r.randint(1, 12)))


class Files:
    """Files, FIFOs, symlinks and shared memory for t=f, t=t and t=s. What is
    made is logged, so a saved step can make it again."""

    def __init__(self, dir, tag):
        self.dir = dir
        self.tag = tag
        self.n = 0
        self.log = []

    def act(self, a):
        self.log.append([a[0]] + [x if isinstance(x, str) else
                                  base64.b64encode(x).decode() for x in a[1:]])
        self.apply(a)

    @staticmethod
    def apply(a):
        kind, path = a[0], a[1]
        for p in (path, path + ".target"):
            if os.path.lexists(p) and kind != "symlink":
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p, ignore_errors=True)
                else:
                    os.unlink(p)
        if kind == "file":
            with open(path, "wb") as f:
                f.write(a[2])
        elif kind == "fifo":
            os.mkfifo(path)
        elif kind == "symlink":
            if os.path.lexists(path):
                os.unlink(path)
            os.symlink(a[2], path)
        elif kind == "mkdir":
            os.mkdir(path)
        elif kind == "sparse":
            with open(path, "wb") as f:
                f.truncate(300 * 1024 * 1024)

    @classmethod
    def replay(cls, log):
        for a in log:
            args = [a[0], a[1]] + [base64.b64decode(x) if a[0] == "file" else x
                                   for x in a[2:]]
            cls.apply(args)

    def medium(self, rng, t, data):
        self.n += 1
        kind = rng.random()
        if t == b"s":
            name = "/gymfz-%s-%d" % (self.tag, self.n)
            if kind < 0.85:
                self.act(("file", "/dev/shm" + name, data))
            return name
        base = os.path.join(self.dir, "m%d" % self.n)
        if t == b"t":
            base += "-tty-graphics-protocol"
        if kind < 0.6:
            self.act(("file", base, data))
        elif kind < 0.7:
            self.act(("fifo", base))
        elif kind < 0.8:
            self.act(("file", base + ".target", data))
            self.act(("symlink", base, base + ".target"))
        elif kind < 0.85:
            self.act(("symlink", base, base + ".missing"))
        elif kind < 0.9:
            self.act(("mkdir", base))
        elif kind < 0.95:
            # Sparse and big: past the size limit.
            self.act(("sparse", base))
        else:
            return rng.choice([base + "/nothing", "/proc/self/status",
                               "/dev/zero", "/etc/hostname", "", "relative",
                               "/" * 3000])
        return base

    def cleanup(self):
        for p in glob.glob("/dev/shm/gymfz-%s-*" % self.tag):
            try:
                os.unlink(p)
            except OSError:
                pass
        shutil.rmtree(self.dir, ignore_errors=True)


READER = r'''
import os, sys, threading, tty
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    tty.setraw(0)
except Exception:
    pass
def drain():
    while True:
        try:
            if not os.read(0, 65536):
                return
        except OSError:
            return
threading.Thread(target=drain, daemon=True).start()
while True:
    d = os.read(fd, 65536)
    while d:
        try:
            n = os.write(1, d)
        except OSError:
            os._exit(0)
        d = d[n:]
'''

QUERIES = re.compile(
    rb"\x1b\[0?c|\x1b\[>0?c|\x1b\[>0?q|\x1b\[\?u|\x1b\[\?(\d+)\$p|"
    rb"\x1b\[(1[468])t|\x1b\](1[0-2]);\?(?:\x1b\\|\x07)|"
    rb"\x1b_G([^\x1b]*)\x1b\\|\x1b\]99;([^\x07\x1b]*)(?:\x1b\\|\x07)|"
    rb"\x1b\[\?996n")


class Terminal:
    """A tmux client in a pty: the master is the terminal."""

    def __init__(self, h, answer=1.0, slow=False, size=(24, 80, 10, 20)):
        self.h = h
        self.answer_p = answer
        self.slow = slow
        self.r = random.Random(h.seed * 7 + h.nterm)
        h.nterm += 1
        self.lock = threading.Lock()
        self.alive = True
        self.kflags = 0
        # Not forkpty: this process has threads, so fork and exec at once.
        self.fd, slave = os.openpty()
        env = dict(h.env)
        # setsid -c: its own session with the pty as controlling terminal
        # (setsid does not fork, the child is not a group leader).
        self.proc = subprocess.Popen(
            ["setsid", "-c"] + h.base + ["attach", "-t", "fz"], stdin=slave,
            stdout=slave, stderr=slave, env=env, close_fds=True)
        os.close(slave)
        self.pid = self.proc.pid
        self.resize(*size)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def resize(self, rows, cols, xp, yp):
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, cols, cols * xp, rows * yp))
            os.kill(self.pid, signal.SIGWINCH)
        except OSError:
            pass

    def write(self, data):
        with self.lock:
            try:
                while data:
                    n = os.write(self.fd, data)
                    data = data[n:]
            except OSError:
                pass

    def reply(self, m):
        if self.r.random() >= self.answer_p:
            return
        s = m.group(0)
        if s.startswith(b"\x1b[") and s.endswith(b"c"):
            if b">" in s:
                self.write(b"\x1b[>1;4000;29c")
            else:
                self.write(b"\x1b[?62;4;22;52c")
        elif s.endswith(b"q"):
            self.write(b"\x1bP>|kitty(0.49.1)\x1b\\")
        elif s == b"\x1b[?u":
            self.write(b"\x1b[?%du" % self.kflags)
        elif m.group(1) is not None:
            mode = int(m.group(1))
            st = 2 if mode in (2026, 2027, 1016, 2048, 1004, 2004) else 0
            self.write(b"\x1b[?%d;%d$y" % (mode, st))
        elif m.group(2) is not None:
            n = int(m.group(2))
            if n == 14:
                self.write(b"\x1b[4;480;800t")
            elif n == 16:
                self.write(b"\x1b[6;20;10t")
            else:
                self.write(b"\x1b[8;24;80t")
        elif m.group(3) is not None:
            self.write(b"\x1b]" + m.group(3) + b";rgb:0000/0000/0000\x1b\\")
        elif m.group(4) is not None:
            keys = m.group(4).split(b";", 1)[0]
            if b"a=q" in keys or self.r.random() < 0.02:
                ident = re.search(rb"(?:^|,)i=(\d+)", keys)
                i = ident.group(1) if ident else b"1"
                self.write(b"\x1b_Gi=" + i + b";OK\x1b\\")
        elif m.group(5) is not None:
            meta = m.group(5).split(b";", 1)[0]
            if b"p=?" in meta:
                ident = re.search(rb"(?:^|:)i=([^:;]*)", meta)
                i = ident.group(1) if ident else b""
                self.write(b"\x1b]99;i=" + i + b":p=?;a=focus,report:"
                           b"o=always,unfocused:u=0,1,2:p=title,body,?,alive:"
                           b"c=1:w=1\x1b\\")
            elif b"p=alive" in meta:
                ident = re.search(rb"(?:^|:)i=([^:;]*)", meta)
                i = ident.group(1) if ident else b""
                self.write(b"\x1b]99;i=" + i + b":p=alive;\x1b\\")
        elif s == b"\x1b[?996n":
            self.write(b"\x1b[?997;1n")

    def read(self):
        buf = b""
        while self.alive:
            try:
                data = os.read(self.fd, 4096 if self.slow else 65536)
            except OSError:
                break
            if not data:
                break
            self.h.term_out += len(data)
            buf += data
            pos = 0
            for m in QUERIES.finditer(buf):
                self.reply(m)
                pos = m.end()
            buf = buf[max(pos, len(buf) - 512):]
            if self.slow:
                time.sleep(0.01)
        self.alive = False

    def close(self):
        self.alive = False
        try:
            os.kill(self.pid, signal.SIGCONT)
            os.kill(self.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            self.proc.wait(timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


class Failure(Exception):
    def __init__(self, kind, detail):
        super().__init__(kind + ": " + detail)
        self.kind = kind
        self.detail = detail


class Harness:
    def __init__(self, tmux, seed, workdir, preconfigure, answer, slow,
                 clear_on_attach=False):
        self.tmux = tmux
        self.seed = seed
        self.dir = workdir
        self.nterm = 0
        self.nfifo = 0
        self.term_out = 0
        self.sockdir = os.path.join(workdir, "sock")
        os.makedirs(self.sockdir, exist_ok=True)
        self.sandir = os.path.join(workdir, "san")
        os.makedirs(self.sandir, exist_ok=True)
        # A fixed place, so a saved step names the same files again.
        self.files = Files("/tmp/gymfz-%d" % seed, str(seed))
        self.files.cleanup()
        os.makedirs(self.files.dir, exist_ok=True)
        self.reader = os.path.join(workdir, "reader.py")
        with open(self.reader, "w") as f:
            f.write(READER)
        conf = os.path.join(workdir, "tmux.conf")
        lines = [
            "set -g status off", "set -g history-limit 500",
            "set -s escape-time 10", "set -s extended-keys on",
            "set -g allow-passthrough on", "set -s set-clipboard on",
            "set -s focus-events on", "set -g mouse on",
            "set -g prefix None", "set -g prefix2 None",
            "unbind -a -T prefix", "unbind -a -T root",
            "unbind -a -T copy-mode", "unbind -a -T copy-mode-vi",
            "set -g remain-on-exit off", "set -s exit-empty off",
            "set -s clear-on-attach %s" % ("on" if clear_on_attach
                                           else "off"),
        ]
        if preconfigure:
            lines.append("set -as terminal-features ',xterm-256color:"
                         "kittykeys:kittygraphics:notify:textsize:graphemes:"
                         "pointer:mousepixels:sync:extkeys:RGB:usstyle:"
                         "focus:title:osc7:clipboard:hyperlinks'")
        with open(conf, "w") as f:
            f.write("\n".join(lines) + "\n")
        self.env = {
            "TMUX_TMPDIR": self.sockdir,
            "TERM": "xterm-256color",
            "LC_ALL": "C.UTF-8",
            "ASAN_OPTIONS": "detect_leaks=0:log_path=%s/asan:"
                            "abort_on_error=0:halt_on_error=1" % self.sandir,
            "UBSAN_OPTIONS": "print_stacktrace=1:halt_on_error=1:"
                             "log_path=%s/ubsan" % self.sandir,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", "/tmp"),
            "TMPDIR": "/tmp",
        }
        self.base = [tmux, "-Lfz", "-f" + conf]
        if os.environ.get("FUZZ_VERBOSE"):
            # Logs (tmux-server-PID.log) in the current directory.
            self.base.insert(1, "-vv")
        # The server's log (-v, in the work directory), for a server that
        # ends with fatal(), which says why only there.
        self.log = bool(os.environ.get("FUZZ_LOG"))
        self.answer = answer
        self.slow = slow
        self.terms = []
        self.pane = None
        self.marker = 0
        self.pid = None
        self.server = None
        self.errfile = None
        self.ended = "unknown"

    def run(self, *args, timeout=60, check=False):
        env = dict(self.env)
        try:
            p = subprocess.run(self.base + list(args), env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure("hang", "command %s did not finish" % (args,))
        if check and p.returncode != 0:
            raise Failure("command", "%s: %s" % (args,
                                                  p.stderr.decode().strip()))
        return p.stdout.decode(errors="replace")

    def reader_cmd(self):
        self.nfifo += 1
        fifo = os.path.join(self.dir, "fifo%d" % self.nfifo)
        os.mkfifo(fifo)
        self.fifo = fifo
        return "exec python3 %s %s" % (self.reader, fifo)

    def start(self):
        # The server in the foreground (-D), so its stderr (where UBSan
        # writes when built with ASan too) and exit status are ours.
        self.errfile = os.path.join(self.sandir, "..", "server.stderr")
        self.server = subprocess.Popen(
            self.base + (["-v"] if self.log else []) + ["-D"], env=self.env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=open(self.errfile, "wb"), cwd=self.dir)
        self.pid = self.server.pid
        # Only once its socket is there: a client before then would start
        # a second server.
        sock = os.path.join(self.sockdir, "tmux-%d" % os.getuid(), "fz")
        end = time.time() + 30
        while True:
            try:
                with socket.socket(socket.AF_UNIX) as so:
                    so.connect(sock)
                break
            except OSError:
                pass
            if time.time() > end or self.server.poll() is not None:
                self.check()
                raise Failure("start", "no server on %s" % sock)
            time.sleep(0.01)
        self.run("new-session", "-d", "-s", "fz", "-x", "80", "-y", "24",
                 self.reader_cmd(), check=True)
        self.pane = self.run("display", "-p", "-t", "fz", "#{pane_id}").strip()
        self.attach()
        self.sync()

    def attach(self):
        self.terms.append(Terminal(self, self.answer, self.slow))

    def stop(self):
        for t in self.terms:
            t.close()
        self.terms = []
        try:
            self.run("kill-server", timeout=20)
        except Failure:
            pass
        if self.server is None:
            self.files.cleanup()
            return
        end = time.time() + 20
        while time.time() < end and self.server_alive():
            time.sleep(0.02)
        if self.server.poll() is None:
            self.server.kill()
            self.server.wait()
        self.files.cleanup()

    def server_alive(self):
        # The server is our child: how it ended.
        rc = self.server.poll()
        if rc is None:
            return True
        self.ended = ("killed by signal %d" % -rc if rc < 0 else
                      "exit status %d" % rc)
        return False

    def log_tail(self):
        path = os.path.join(self.dir, "tmux-server-%d.log" % self.pid)
        try:
            with open(path, errors="replace") as f:
                lines = f.readlines()
        except OSError:
            return ""
        fatal = [x for x in lines if "fatal" in x]
        return "\n" + "".join(fatal + lines[-15:])

    def sanitizer(self):
        reports = sorted(glob.glob(os.path.join(self.sandir, "*")))
        text = ""
        if self.errfile:
            try:
                with open(self.errfile, errors="replace") as f:
                    err = f.read()
                if re.search(r"runtime error:|Sanitizer", err):
                    text += "== server stderr\n" + err
            except OSError:
                pass
        if not reports and not text:
            return None
        for p in reports:
            with open(p, errors="replace") as f:
                text += "== %s\n%s" % (os.path.basename(p), f.read())
        return text

    def check(self):
        san = self.sanitizer()
        if san:
            raise Failure("sanitizer", san)
        if not self.server_alive():
            raise Failure("crash", "server %d exited (%s)%s" %
                          (self.pid, self.ended, self.log_tail()))

    def pane_write(self, data):
        try:
            fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            # No reader: the pane is gone or not started yet.
            end = time.time() + 5
            while True:
                try:
                    fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
                    break
                except OSError:
                    if time.time() > end:
                        self.check()
                        raise Failure("reader", "no reader on %s" % self.fifo)
                    time.sleep(0.01)
        try:
            end = time.time() + 30
            while data:
                try:
                    n = os.write(fd, data)
                    data = data[n:]
                except BlockingIOError:
                    if time.time() > end:
                        self.check()
                        raise Failure("hang", "pane output not read")
                    time.sleep(0.005)
        finally:
            os.close(fd)

    def sync(self):
        """Wait until everything written to the pane has been parsed."""
        self.marker += 1
        mark = "fz%d" % self.marker
        self.pane_write(b"\x18\x1b\\\x1b]7;" + mark.encode() + b"\x07")
        end = time.time() + 30
        while time.time() < end:
            self.check()
            out = self.run("display", "-p", "-t", self.pane, "#{pane_path}")
            if out.strip() == mark:
                return
            time.sleep(0.005)
        self.check()
        raise Failure("hang", "marker %s not parsed" % mark)

    def invariants(self):
        out = self.run("display", "-p", "-t", self.pane,
                       "#{cursor_x} #{cursor_y} #{pane_width} "
                       "#{pane_height} #{alternate_on}").split()
        if len(out) != 5:
            raise Failure("invariant", "display gave %r" % out)
        cx, cy, w, h, alt = map(int, out)
        # Upstream tmux leaves the cursor of the alternate screen (1047)
        # outside a pane made smaller (split-window): not checked there.
        if alt:
            return
        if cx > w or cy >= h:
            raise Failure("invariant", "cursor %d,%d in %dx%d" %
                          (cx, cy, w, h))

    def ensure_pane(self):
        """The fuzzed pane, made again if a step killed it."""
        panes = self.run("list-panes", "-a", "-F", "#{pane_id}").split()
        if self.pane in panes:
            return
        if not self.run("list-sessions", "-F", "#{session_name}").strip():
            self.run("new-session", "-d", "-s", "fz", self.reader_cmd(),
                     check=True)
        else:
            self.run("new-window", "-t", "fz", self.reader_cmd(), check=True)
        self.pane = self.run("display", "-p", "-t", "fz",
                             "#{pane_id}").strip()

    def clients(self):
        return self.run("list-clients", "-F", "#{client_name}").split()

    def ensure_terminal(self):
        self.terms = [t for t in self.terms if t.alive or t.close()]
        if not self.terms:
            self.attach()


def gen_steps(seed, n):
    """The steps for a seed, as data (so they can be saved and shrunk)."""
    r = random.Random(seed)
    steps = []
    for _ in range(n):
        k = r.random()
        if k < 0.55:
            steps.append({"k": "pane", "seed": r.randint(0, 2 ** 31),
                          "split": r.random() < 0.3})
        elif k < 0.70:
            steps.append({"k": "term", "seed": r.randint(0, 2 ** 31)})
        elif k < 0.80:
            steps.append({"k": "keys", "keys": [r.choice(KEYS) for _ in
                                                range(r.randint(1, 4))]})
        else:
            steps.append({"k": "life", "seed": r.randint(0, 2 ** 31)})
    return steps


LIFE = ["resize-window", "term-size", "detach", "attach2", "suspend",
        "respawn", "kill", "split", "swap", "select-window", "new-window",
        "clear-history", "capture", "copy-mode", "zoom", "window-size",
        "kill-other", "send-mouse", "refresh"]


def do_life(h, r):
    what = r.choice(LIFE)
    if what == "resize-window":
        h.run("resize-window", "-t", h.pane, "-x",
              str(r.choice([1, 2, 5, 20, 80, 81, 200, 500])), "-y",
              str(r.choice([1, 2, 5, 24, 25, 100])))
    elif what == "term-size":
        t = r.choice(h.terms) if h.terms else None
        if t:
            t.resize(r.choice([1, 2, 10, 24, 50]),
                     r.choice([1, 2, 10, 80, 200]),
                     r.choice([0, 1, 7, 10, 30]), r.choice([0, 1, 13, 20]))
    elif what == "detach":
        if h.terms:
            t = h.terms.pop(r.randrange(len(h.terms)))
            if r.random() < 0.5:
                h.run("detach-client", "-s", "fz")
            t.close()
    elif what == "attach2":
        if len(h.terms) < 3:
            h.attach()
    elif what == "suspend":
        if h.terms:
            names = h.clients()
            if names:
                h.run("suspend-client", "-t", r.choice(names))
            time.sleep(r.choice([0, 0.01, 0.1]))
            for t2 in h.terms:
                try:
                    os.kill(t2.pid, signal.SIGCONT)
                except OSError:
                    pass
    elif what == "respawn":
        h.run("respawn-pane", "-k", "-t", h.pane, h.reader_cmd())
    elif what == "kill":
        h.run("kill-pane", "-t", h.pane)
    elif what == "split":
        h.run("split-window", "-d", "-t", h.pane, r.choice(["-h", "-v"]),
              "exec sleep 100000")
    elif what == "swap":
        h.run("swap-pane", "-d", "-s", h.pane, "-t", "{next}")
    elif what == "select-window":
        h.run("select-window", "-t", r.choice(["fz:{next}", "fz:{last}",
                                               h.pane]))
    elif what == "new-window":
        h.run("new-window", "-d", "-t", "fz", "exec sleep 100000")
    elif what == "clear-history":
        h.run("clear-history", "-t", h.pane)
    elif what == "capture":
        h.run("capture-pane", "-p", "-t", h.pane,
              *r.choice([["-e"], ["-e", "-C"], ["-e", "-J", "-S", "-"],
                         ["-C"], ["-a"], ["-N", "-T"]]))
    elif what == "copy-mode":
        h.run("copy-mode", "-t", h.pane)
        h.run("send-keys", "-t", h.pane, "-X",
              r.choice(["history-top", "cursor-down", "search-backward",
                        "select-line", "copy-selection", "page-up"]))
        h.run("send-keys", "-t", h.pane, "-X", "cancel")
    elif what == "zoom":
        h.run("resize-pane", "-Z", "-t", h.pane)
    elif what == "window-size":
        h.run("set", "-w", "-t", h.pane, "window-size",
              r.choice(["latest", "largest", "smallest", "manual"]))
    elif what == "kill-other":
        panes = [p for p in h.run("list-panes", "-a", "-F",
                                  "#{pane_id}").split() if p != h.pane]
        if panes:
            h.run("kill-pane", "-t", r.choice(panes))
    elif what == "send-mouse":
        if h.terms:
            r2 = random.Random(r.randint(0, 2 ** 31))
            t = r.choice(h.terms)
            t.write(b"\x1b[<%d;%d;%d%s" % (r2.choice([0, 1, 2, 32, 35, 64, 65]),
                                           r2.randint(0, 900),
                                           r2.randint(0, 500),
                                           r2.choice([b"M", b"m"])))
    elif what == "refresh":
        for name in h.clients():
            h.run("refresh-client", "-t", name)


def run_step(h, step):
    k = step["k"]
    if k == "pane":
        r = random.Random(step["seed"])
        g = Gen(r, h.files)
        if "data" in step:
            Files.replay(step.get("files", []))
            data = step["data"].encode("latin-1")
        else:
            h.files.log = []
            data = g.pane_bytes()
            step["files"] = h.files.log
        step["data"] = data.decode("latin-1")
        if step.get("split") and len(data) > 1:
            cut = step.get("cut") or r.randint(1, len(data) - 1)
            step["cut"] = cut = min(cut, len(data) - 1)
            h.pane_write(data[:cut])
            h.pane_write(data[cut:])
        else:
            h.pane_write(data)
    elif k == "term":
        r = random.Random(step["seed"])
        g = Gen(r, h.files)
        data = step["data"].encode("latin-1") if "data" in step \
            else g.term_bytes()
        step["data"] = data.decode("latin-1")
        h.ensure_terminal()
        if len(data) > 1 and r.random() < 0.4:
            # Split, so tmux sees a partial sequence first.
            cut = step.get("cut") or r.randint(1, len(data) - 1)
            step["cut"] = cut = min(cut, len(data) - 1)
            h.terms[0].write(data[:cut])
            time.sleep(0.02)
            h.terms[0].write(data[cut:])
        else:
            h.terms[0].write(data)
    elif k == "keys":
        h.run("send-keys", "-t", h.pane, *step["keys"])
    elif k == "life":
        do_life(h, random.Random(step["seed"]))
    h.check()
    h.ensure_pane()
    h.ensure_terminal()
    h.sync()
    h.invariants()


def options_for(seed):
    r = random.Random(seed ^ 0x5eed)
    return {"preconfigure": r.random() < 0.5,
            "answer": r.choice([1.0, 1.0, 0.9, 0.5, 0.0]),
            "slow": r.random() < 0.15,
            "clear_on_attach": r.random() < 0.5}


def execute(tmux, seed, steps, opts, keep=None, quiet=True):
    """Run steps in a fresh server. Returns (failure or None, steps run)."""
    workdir = tempfile.mkdtemp(prefix="fz%d-" % seed,
                               dir=os.environ.get("FUZZ_TMP"))
    h = Harness(tmux, seed, workdir, opts["preconfigure"], opts["answer"],
                opts["slow"], opts.get("clear_on_attach", False))
    done = []
    failure = None
    try:
        h.start()
        for step in steps:
            done.append(step)
            run_step(h, step)
    except Failure as e:
        failure = e
    except Exception as e:  # The harness itself: report as such.
        failure = Failure("harness", "%s: %s" % (type(e).__name__, e))
    finally:
        try:
            h.stop()
        except Exception:
            pass
        # A report written while the server stopped (at exit) counts too.
        san = h.sanitizer()
        if san and (failure is None or failure.kind != "sanitizer"):
            failure = Failure("sanitizer", san)
        if keep and failure:
            for p in glob.glob(os.path.join(h.sandir, "*")):
                shutil.copy(p, keep + "." + os.path.basename(p))
        if not (failure and os.environ.get("FUZZ_KEEP")):
            shutil.rmtree(workdir, ignore_errors=True)
        elif failure:
            failure.detail += "\n(kept %s)" % workdir
    return failure, done


def signature(f):
    """What makes two failures the same: the kind and the first frame in
    tmux's source, or the message."""
    if f is None:
        return None
    if f.kind == "sanitizer":
        m = re.search(r"(SUMMARY: \S+: \S+)", f.detail)
        frames = re.findall(r"#\d+ 0x[0-9a-f]+ in (\w+) (\S+\.c):(\d+)",
                            f.detail)
        top = frames[0][:2] if frames else ()
        ub = re.search(r"(\S+\.c:\d+:\d+: runtime error: [^\n]*)", f.detail)
        return ("sanitizer", m.group(1) if m else "", top,
                ub.group(1).split(":")[0] if ub else "")
    if f.kind == "invariant":
        return ("invariant", f.detail.split(" ")[0])
    return (f.kind,)


def fuzz_one(args):
    """Fuzz seed after seed until the deadline. Each failure is saved
    (fail-SEED.json); the next seed starts a fresh server."""
    tmux, seed, nsteps, deadline, out, skip, base = args
    total = 0
    found = []
    while time.time() < deadline:
        opts = options_for(seed)
        steps = gen_steps(seed, nsteps)
        failure, done = execute(tmux, seed, steps, opts,
                                keep=os.path.join(out, "fail-%d" % seed))
        total += len(done)
        if failure:
            sig = repr(signature(failure))
            if base:
                # The same steps on the base build: does it fail there too?
                bf, _ = execute(base, seed, json.loads(json.dumps(done)), opts)
                if bf is not None and signature(bf)[:2] == \
                        signature(failure)[:2]:
                    sig += " (also on base)"
            if not any(k in failure.detail for k in skip):
                path = os.path.join(out, "fail-%d.json" % seed)
                with open(path, "w") as f:
                    json.dump({"seed": seed, "opts": opts, "steps": done,
                               "kind": failure.kind, "signature": sig,
                               "base": base,
                               "detail": failure.detail[:20000]}, f)
                found.append((seed, sig, failure.detail[:3000]))
        seed += 1000003
    return total, found


def tokens(data):
    tok = re.compile(rb"\x1b_G[^\x1b]*\x1b\\|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
                     rb"|\x1b\[[0-9;:?<>=!$]*[ -/]*[@-~]|\x1b.|"
                     rb"[\xc0-\xf7][\x80-\xbf]*|.", re.S)
    return tok.findall(data)


def ddmin(items, fails):
    n = 2
    while len(items) >= 2:
        chunk = max(1, len(items) // n)
        subsets = [items[i:i + chunk] for i in range(0, len(items), chunk)]
        reduced = False
        for i in range(len(subsets)):
            rest = [t for j, s in enumerate(subsets) if j != i for t in s]
            if fails(rest):
                items = rest
                n = max(n - 1, 2)
                reduced = True
                break
        if not reduced:
            if n >= len(items):
                break
            n = min(len(items), n * 2)
    return items


def shrink(tmux, path, tries=3):
    with open(path) as f:
        case = json.load(f)
    opts = case["opts"]
    want = None

    def fails(steps):
        nonlocal want
        for _ in range(tries):
            f, _ = execute(tmux, case["seed"], json.loads(json.dumps(steps)),
                           opts)
            if f is not None and (want is None or signature(f) == want):
                if want is None:
                    want = signature(f)
                return True
        return False

    steps = case["steps"]
    if not fails(steps):
        print("does not fail again")
        return None
    print("signature:", want)
    steps = ddmin(steps, fails)
    print("%d steps" % len(steps))
    for i, s in enumerate(steps):
        if "data" not in s:
            continue
        toks = tokens(s["data"].encode("latin-1"))

        def tfails(ts, i=i):
            trial = json.loads(json.dumps(steps))
            trial[i]["data"] = b"".join(ts).decode("latin-1")
            trial[i].pop("split", None)
            return fails(trial)
        toks = ddmin(toks, tfails)
        steps[i]["data"] = b"".join(toks).decode("latin-1")
        steps[i].pop("split", None)
    out = path.replace(".json", ".min.json")
    with open(out, "w") as f:
        json.dump({"seed": case["seed"], "opts": opts, "steps": steps,
                   "signature": list(map(str, want))}, f, indent=1)
    for s in steps:
        print(json.dumps(s)[:400])
    print("written", out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tmux", required=True)
    ap.add_argument("--seeds", default="1-8")
    ap.add_argument("--steps", type=int, default=200)
    ap.add_argument("--minutes", type=float, default=1)
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--out", default="fuzz-proto-out")
    ap.add_argument("--replay")
    ap.add_argument("--shrink")
    ap.add_argument("--base", help="a tmux to replay failures on, to tell "
                    "new failures from old ones")
    ap.add_argument("--skip", action="append", default=[],
                    help="ignore failures whose report contains this")
    a = ap.parse_args()
    os.environ.pop("TMUX", None)
    tmux = os.path.abspath(a.tmux)
    if a.shrink:
        shrink(tmux, a.shrink)
        return
    if a.replay:
        with open(a.replay) as f:
            case = json.load(f)
        failure, done = execute(tmux, case["seed"], case["steps"],
                                case["opts"])
        print("replay:", "ok" if failure is None else failure.kind)
        if failure:
            print(failure.detail[:4000])
        sys.exit(1 if failure else 0)
    os.makedirs(a.out, exist_ok=True)
    base = os.path.abspath(a.base) if a.base else None
    lo, _, hi = a.seeds.partition("-")
    seeds = list(range(int(lo), int(hi or lo) + 1))
    deadline = time.time() + a.minutes * 60
    jobs = a.jobs or len(seeds)
    with multiprocessing.Pool(jobs) as pool:
        results = pool.map(fuzz_one, [(tmux, s, a.steps, deadline, a.out,
                                       a.skip, base) for s in seeds])
    steps = sum(r[0] for r in results)
    bysig = {}
    for _, found in results:
        for seed, sig, detail in found:
            bysig.setdefault(sig, []).append((seed, detail))
    for sig, cases in bysig.items():
        print("FAIL %s: %d times, first seed %d" % (sig, len(cases),
                                                    cases[0][0]))
        print("  " + "\n  ".join(cases[0][1].splitlines()[:40]))
    print("%d steps, %d distinct failures" % (steps, len(bysig)))
    sys.exit(1 if bysig else 0)


if __name__ == "__main__":
    main()
