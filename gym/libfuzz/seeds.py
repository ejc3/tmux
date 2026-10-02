"""Seed corpora and dictionaries for tmux's libFuzzer harnesses.

    python3 gym/libfuzz/seeds.py OUTDIR

Writes OUTDIR/{input,kgfx,keys}/ seeds (one sequence per file) and
OUTDIR/{kgfx,keys}.dict. The kgfx seeds are pane output for
input-kgfx-fuzzer (and input-fuzzer); keys seeds are FLAGS PANE \\377\\377
TERMINAL for tty-keys-fuzzer.
"""

import base64
import os
import sys
import zlib
import struct

ST = b'\033\\'


def b64(d):
    return base64.b64encode(d)


def png(w, h):
    raw = b''.join(b'\0' + b'\x80\x40\x20' * w for _ in range(h))

    def chunk(k, body):
        return (struct.pack('>I', len(body)) + k + body
                + struct.pack('>I', zlib.crc32(k + body)))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def gfx(k, p=b''):
    return b'\033_G' + k + (b';' + p if p else b'') + ST


PH = '\U0010EEEE'.encode()
D = [c.encode() for c in '̅̍̎̐̒']
RGB1 = b64(b'\1\2\3')

PANE = [
    gfx(b'a=T,f=24,s=1,v=1,i=5,U=1', RGB1) + PH + D[0] + D[0] + PH + D[0] + D[1],
    gfx(b'a=t,f=32,s=2,v=2,I=7', b64(b'\1\2\3\4' * 4)) + gfx(b'a=d,d=N,I=7'),
    gfx(b'a=t,f=100,i=9', b64(png(2, 2))) + gfx(b'a=p,i=9,c=2,r=1,p=3')
    + gfx(b'a=d,d=i,i=9,p=3'),
    gfx(b'a=t,f=24,s=1,v=1,o=z,i=4', b64(zlib.compress(b'\1\2\3'))),
    gfx(b'a=t,f=24,s=8,v=8,i=3,m=1', b'AAAA') + gfx(b'm=1', b'AAAA')
    + gfx(b'm=0', b'AAAA'),
    gfx(b'a=t,f=24,s=8,v=8,i=3,m=1', b'AAAA') + gfx(b'a=d,d=I,i=3'),
    gfx(b'a=q,i=31,s=1,v=1,f=24', b'AAAA'),
    gfx(b'a=t,f=24,s=1,v=1,t=f,i=8', b64(b'/etc/hostname')),
    gfx(b'a=t,f=24,s=1,v=1,t=s,i=8', b64(b'nonexistent')),
    gfx(b'a=f,i=5,f=32,s=2,v=2', b64(b'\1\2\3\4' * 4))
    + gfx(b'a=a,i=5,s=3') + gfx(b'a=c,i=5,r=1,c=2'),
    gfx(b'a=p,i=%d,U=1' % 0x1000033) + b'\033[38;2;0;0;51m' + PH + D[0]
    + D[0] + D[1] + PH,
    b'\033[4h' + PH + D[0] + D[0] + D[2] + b'\033[4l',
    b'\033[?1049h' + gfx(b'a=T,f=24,s=1,v=1,i=6', RGB1) + b'\033[?1049l'
    + gfx(b'a=d,d=a'),
    b'a\033]66;w=2;b\007c\033]66;w=0;de\007\033]66;w=3;e\xcc\x81\007'
    b'\033]66;s=2;x\007\033]66;w=2;\xf0\007\033]66;w=6;' + b'x' * 40 + b'\007',
    b'\033[1;79H\033]66;w=3;xyz\007\r\n',
    b'\033]22;>crosshair,wait' + ST + b'\033]22;?__current__' + ST
    + b'\033]22;<' + ST + b'\033]22;pointer' + ST + b'\033c',
    b'\033]99;i=n1:d=0;title' + ST + b'\033]99;i=n1:p=body:a=report;b' + ST
    + b'\033]99;;anon' + ST + b'\033]99;i=q:p=?;' + ST
    + b'\033]99;i=a:p=alive;' + ST + b'\033]99;i=n1:p=close;' + ST,
    b'\033]9;hi\007\033]9;9;/tmp\007\033]9;4;1;50\007\033]777;notify;t;b\007',
    b'\033[>5u\033[?u\033[=3;2u\033[<u\033[<20u\033[>31u',
    b'\033[?2027h\033[?2048h\033[?1016h\033[?1000h\033[?1006h\033[!p',
    '\U0001F469‍\U0001F4BB 1️⃣ é̂'.encode(),
]

TERMINAL = [
    (0x01, b'', b'\033[?62;22;52c\033[>1;4000;29c\033P>|kitty(0.49.1)' + ST),
    (0x01, b'', b'\033_Gi=31;OK' + ST + b'\033[?0u\033[?2027;2$y'
     b'\033[?1016;2$y\033[?2026;2$y\033[?2048;1$y'),
    (0x01, b'', b'\033]10;rgb:ffff/ffff/ffff' + ST + b'\033]11;rgb:0/0/0'
     + ST + b'\033[4;768;1280t\033[6;32;16t'),
    (0x20, b'', b'\033[97;5u\033[57376u\033[13;2~\033[57399u\033[97:65;2u'
     b'\033[27u\033[127;3u\033[57441;2:3u\033[1;5P\033[0;;105u\033[32;3:3u'),
    (0x00, b'', b'abc\x01\033[A\033OP\033[15~\033[1;5A\033x\033[200~p\033[201~'
     b'\033[I\033[O'),
    (0x1a, b'', b'\033[<0;100;200M\033[<0;100;200m\033[<35;1;1M'
     b'\033[<64;5;5M\033[<0;0;0M\033[<0;99999;99999M'),
    (0x08, b'', b'\033[M #!\033[<0;3;2M'),
    (0x00, b'\033]99;i=w:a=report;w' + ST, b'\033]99;i=t0_w;' + ST
     + b'\033]99;i=t0_w:p=close;' + ST),
    (0x00, b'\033]99;i=q:p=?;' + ST, b'\033]99;i=t0_q:p=?;a=focus,report'
     + ST),
    (0x00, b'\033]99;i=a:p=alive;' + ST, b'\033]99;i=t0_a:p=alive;t0_x,t1_y'
     + ST),
    (0x01, gfx(b'a=q,i=31,s=1,v=1,f=24', b'AAAA'), b'\033_Gi=31;OK' + ST),
    (0x00, b'\033]52;c;?\007', b'\033]52;c;aGVsbG8=\007'),
    (0x80, b'', b'\033[1;5'),
    (0x80, b'', b'\033P>|kitty('),
]

KGFX_DICT = [
    b'\033_G', b'\033\\', b'a=T', b'a=t', b'a=p', b'a=d', b'a=q', b'a=f',
    b'a=a', b'a=c', b'f=24', b'f=32', b'f=100', b't=f', b't=t', b't=s',
    b'o=z', b'm=1', b'm=0', b'U=1', b'q=2', b'i=', b'I=', b'p=', b'c=', b'r=',
    b'd=a', b'd=A', b'd=i', b'd=I', b'd=n', b'd=N', b'd=p', b'd=c', b'd=z',
    b'x=', b'y=', b'w=', b'h=', b'X=', b'Y=', b'z=', b'C=1', b's=', b'v=',
    b'S=', b'O=', b'H=', b'V=', PH, D[0], D[1], D[2], D[3],
    b'\033]66;', b'w=2;', b's=2;', b'\033]22;', b'>', b'<', b'?__current__',
    b'\033]99;', b'p=?', b'p=alive', b'p=close', b'p=body', b'p=title',
    b'a=report', b'c=1', b'd=0', b'e=1', b'\033]9;', b'\033]777;notify;',
    b'\033[>', b'u', b'\033[=', b'\033[<', b'\033[?u', b'\033[?2027h',
    b'\033[?2048h', b'\033[?1016h', b'\033[!p', b'\033[4h', b'\033[?1049h',
    b'\033c', b'\033[38;2;', b'\033[38;5;', b'\xe2\x80\x8d', b'\xef\xb8\x8f',
]
KEYS_DICT = KGFX_DICT + [
    b'\377\377', b'\033[?62;', b'c', b'\033[>1;', b'\033P>|', b'kitty(',
    b'XTerm(', b'ghostty ', b'tmux ', b'$y', b'\033[?2027;2$y',
    b'\033[?1016;2$y', b'\033_Gi=31;OK', b'\033_Gi=31;ENOENT:x', b';OK',
    b'\033[<', b'M', b'm', b'\033[M', b'\033[97;5u', b'\033[57376u', b':3u',
    b':2u', b';;', b'\033[13;2~', b'\033[1;5P', b'\033]10;rgb:', b'\033]11;',
    b'\033]4;', b'\033]52;c;', b'\033[4;', b'\033[6;', b't', b'\033[200~',
    b'\033[201~', b'\033[I', b'\033[O', b'\033]99;i=t0_', b'\033]99;i=t0.',
]


def dict_line(b):
    return '"' + ''.join('\\x%02x' % c if c < 0x20 or c > 0x7e or c in b'"\\'
                         else chr(c) for c in b) + '"'


def main():
    out = sys.argv[1]
    for d in ('input', 'kgfx', 'keys'):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    for n, s in enumerate(PANE):
        for d in ('input', 'kgfx'):
            with open(os.path.join(out, d, 'seed%02d' % n), 'wb') as f:
                f.write(s)
    for n, (flags, pane, term) in enumerate(TERMINAL):
        with open(os.path.join(out, 'keys', 'seed%02d' % n), 'wb') as f:
            f.write(bytes([flags]) + pane + b'\377\377' + term)
    for name, words in (('kgfx', KGFX_DICT), ('keys', KEYS_DICT)):
        with open(os.path.join(out, name + '.dict'), 'w') as f:
            for w in words:
                f.write(dict_line(w) + '\n')


if __name__ == '__main__':
    main()
