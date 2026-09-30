"""Draw terminal screens side by side as PNG, with the cells that differ from
the first panel outlined in red.

A panel is a list of rows; a row is text that may carry SGR colour escapes
(capture-pane -e) and OSC 8 links. Only the rows around the differences are
drawn (--context rows either side), with row numbers.

Used by gym/report.py; can also be run on two or more files of rows:
    python3 gym/evidence.py OUT.png "title A" a.txt "title B" b.txt ...
"""

import os
import re
import sys
import unicodedata

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vt  # noqa: E402

MONO = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'
CJK = '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
EMOJI = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf'
CW, CH = 9, 18                     # cell size in pixels
PAD, GAP, HEAD = 10, 16, 40
BG, FG = (30, 30, 30), (220, 220, 220)
RED = (235, 70, 70)
ANSI = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200),
        (188, 63, 188), (17, 168, 205), (229, 229, 229), (102, 102, 102), (241, 76, 76),
        (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219),
        (255, 255, 255)]

_fonts = {}


def font(path, size):
    k = (path, size)
    if k not in _fonts:
        _fonts[k] = ImageFont.truetype(path, size)
    return _fonts[k]


def c256(n):
    if n < 16:
        return ANSI[n]
    if n < 232:
        n -= 16
        return tuple(0 if v == 0 else 55 + v * 40 for v in (n // 36, (n // 6) % 6, n % 6))
    g = 8 + (n - 232) * 10
    return (g, g, g)


SGR = re.compile(r'\x1b\[([0-9;:]*)m')
OSC = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')


def cells(row, cols):
    """A row of text with escapes as cols cells: (char, fg, bg, underline,
    link). A wide character's second cell is None."""
    out = []
    fg, bg, ul, link = None, None, False, False
    i = 0
    row = row.expandtabs(8)
    while i < len(row):
        m = OSC.match(row, i)
        if m:
            link = ';;' not in m.group(0)[:6] and not m.group(0).startswith('\x1b]8;;\x1b')
            i = m.end()
            continue
        m = SGR.match(row, i)
        if m:
            ps = [int(p) if p.isdigit() else 0 for p in re.split('[;:]', m.group(1) or '0')]
            j = 0
            while j < len(ps):
                p = ps[j]
                if p == 0:
                    fg, bg, ul = None, None, False
                elif p == 4:
                    ul = True
                elif p == 24:
                    ul = False
                elif 30 <= p <= 37:
                    fg = ANSI[p - 30]
                elif 90 <= p <= 97:
                    fg = ANSI[p - 82]
                elif 40 <= p <= 47:
                    bg = ANSI[p - 40]
                elif 100 <= p <= 107:
                    bg = ANSI[p - 92]
                elif p == 39:
                    fg = None
                elif p == 49:
                    bg = None
                elif p in (38, 48) and j + 1 < len(ps):
                    if ps[j + 1] == 5 and j + 2 < len(ps):
                        col = c256(ps[j + 2]); j += 2
                    elif ps[j + 1] == 2 and j + 4 < len(ps):
                        col = tuple(ps[j + 2:j + 5]); j += 4
                    else:
                        col = None
                    if p == 38:
                        fg = col
                    else:
                        bg = col
                j += 1
            i = m.end()
            continue
        ch = row[i]
        i += 1
        while i < len(row) and (unicodedata.combining(row[i]) or row[i] in '‍️' or
                                0x1f3fb <= ord(row[i]) <= 0x1f3ff):
            ch += row[i]
            i += 1
        w = max(1, vt.cell_width(ch[0], vt.XTERM))
        out.append((ch, fg, bg, ul, link))
        if w == 2:
            out.append(None)
    out = out[:cols]
    while len(out) < cols:
        out.append((' ', None, None, False, False))
    return out


def text_of(c):
    return ' ' if c is None else c[0]


def draw_glyph(img, d, x, y, ch, fg):
    o = ord(ch[0])
    if o >= 0x1f000 or (0x2600 <= o < 0x2800 and '️' in ch) or o in (0x2705, 0x274c):
        try:
            f = font(EMOJI, 109)
            im = Image.new('RGBA', (140, 130), (0, 0, 0, 0))
            ImageDraw.Draw(im).text((0, 0), ch, font=f, embedded_color=True)
            im = im.crop(im.getbbox() or (0, 0, 1, 1)).resize((2 * CW - 2, CH - 2))
            img.paste(im, (x + 1, y + 1), im)
            return
        except Exception:
            pass
    f = font(CJK, 15) if unicodedata.east_asian_width(ch[0]) in 'WF' else font(MONO, 14)
    d.text((x, y + 1), ch, font=f, fill=fg)


def panel(rows, cols, title, marks, first, last, c0=0, c1=None):
    """Rows first..last and columns c0..c1 of a screen."""
    c1 = cols if c1 is None else c1
    w = (c1 - c0) * CW + 2 * PAD + 30
    h = HEAD + (last - first) * CH + 2 * PAD
    img = Image.new('RGB', (w, h), BG)
    d = ImageDraw.Draw(img)
    d.text((PAD, 10), title, font=font(MONO, 14), fill=(255, 255, 255))
    for r in range(first, last):
        y = HEAD + (r - first) * CH
        d.text((PAD, y + 2), f'{r:3d}', font=font(MONO, 11), fill=(110, 110, 110))
        row = rows[r] if r < len(rows) else [(' ', None, None, False, False)] * cols
        for c in range(c0, c1):
            x = PAD + 30 + (c - c0) * CW
            cell = row[c]
            if cell is None:
                continue
            ch, fg, bg, ul, link = cell
            wide = c + 1 < c1 and row[c + 1] is None
            cw = CW * (2 if wide else 1)
            if bg:
                d.rectangle([x, y, x + cw - 1, y + CH - 1], fill=bg)
            if ch.strip():
                draw_glyph(img, d, x, y, ch, fg or FG)
            if ul or link:
                d.line([x, y + CH - 2, x + cw - 1, y + CH - 2], fill=fg or FG)
        for c in range(c0, c1):
            if (r, c) in marks:
                x = PAD + 30 + (c - c0) * CW
                d.rectangle([x, y, x + CW - 1, y + CH - 1], outline=RED, width=2)
    return img


def compare(panels, cols, context=3, max_rows=26, stack=False, window=None,
            scale=1):
    """panels: [(title, [row text])]. Returns an image, cells differing from
    the first panel outlined. stack puts the panels one above another;
    window shows only that many columns, around the first difference; scale
    enlarges the image (for screens that shrink it to fit, like a phone)."""
    grids = [[cells(r, cols) for r in rows] for _, rows in panels]
    n = max(len(g) for g in grids)
    for g in grids:
        while len(g) < n:
            g.append(cells('', cols))
    diff_rows = set()
    marks = [set() for _ in grids]
    for k, g in enumerate(grids[1:], 1):
        for r in range(n):
            for c in range(cols):
                if text_of(g[r][c]) != text_of(grids[0][r][c]):
                    marks[k].add((r, c))
                    diff_rows.add(r)
    if diff_rows:
        first = max(0, min(diff_rows) - context)
        last = min(n, max(diff_rows) + context + 1)
    else:
        first, last = max(0, n - max_rows), n
    if last - first > max_rows:
        last = first + max_rows
    c0, c1 = 0, cols
    if window is not None and window < cols:
        dcols = sorted(c for m in marks for _, c in m)
        start = dcols[0] - 4 if dcols else 0
        c0 = max(0, min(start, cols - window))
        c1 = c0 + window
        panels = [(f'{t}, cols {c0 + 1}-{c1}', r) for t, r in panels]
    ims = [panel(g, cols, t, marks[k], first, last, c0, c1)
           for k, ((t, _), g) in enumerate(zip(panels, grids))]
    if stack:
        W = max(i.width for i in ims)
        H = sum(i.height for i in ims) + GAP * (len(ims) - 1)
    else:
        W = sum(i.width for i in ims) + GAP * (len(ims) - 1)
        H = max(i.height for i in ims)
    out = Image.new('RGB', (W, H), (60, 60, 60))
    x = y = 0
    for i in ims:
        out.paste(i, (x, y))
        if stack:
            y += i.height + GAP
        else:
            x += i.width + GAP
    if scale != 1:
        out = out.resize((out.width * scale, out.height * scale), Image.NEAREST)
    return out


def main():
    out = sys.argv[1]
    args = sys.argv[2:]
    panels = [(args[i], open(args[i + 1]).read().split('\n')) for i in range(0, len(args), 2)]
    cols = max(80, max(len(l) for _, rows in panels for l in rows) if panels else 80)
    compare(panels, min(cols, 80)).save(out)


if __name__ == '__main__':
    main()
