"""A terminal model for comparing what a program leaves on a terminal when it
runs directly and when it runs inside tmux.

Text and geometry only (no colours): the screen, the scrollback, which rows
wrapped into the next, the cursor, and which screen is active. The behaviours
where real terminals differ are switches (Quirks), so one byte stream can be
replayed on several kinds of terminal. The parser is incremental: feed() may
be called with any split of the stream, which lets a test apply an event (a
resize, or a shift the terminal does without telling anyone) at an exact byte.
"""

import unicodedata
from dataclasses import dataclass, field, replace


# Where each switch stands against the standards (ECMA-48, DEC's VT
# specifications, xterm as the de facto reference):
#   no standard covers it, every terminal chooses: ed2_push, region_sb, grow,
#     shrink, reflow (scrollback does not exist in the standards); tmux_grid,
#     shift_unwraps (which rows are joined is private bookkeeping for copy and
#     reflow); wide (emoji drawing width); nowrap_pending.
#   DEC defines it and some terminals deviate: wrap='sticky' (DEC's last
#     column flag is cleared by cursor movement; PuTTY and Prompt keep it),
#     il_cr=False (DEC and xterm home the column on IL/DL; tmux does not),
#     rep_clamp (REP repeats as if typed and so wraps; tmux stops at the edge),
#     acs=False (not a terminal behaviour: how capture-pane reports the cells).
#   to be checked against DEC STD 070: erase_clears_pending, past_edge.
@dataclass(frozen=True)
class Quirks:
    # After the last column: 'deferred' (xterm: wrap on the next character,
    # any cursor move cancels), 'sticky' (PuTTY, Prompt: only CR or a
    # character cancels, so a move then a character still wraps), 'eager'
    # (wrap at once).
    wrap: str = 'deferred'
    # Taller: 'append' blank rows at the bottom (xterm), or 'pull' rows back
    # from the scrollback at the top and move the cursor down (iTerm2, Prompt).
    grow: str = 'append'
    # Shorter: 'cursor' drops rows below and pushes rows above only as far as
    # needed to keep the cursor (xterm), 'blankfirst' drops blank rows at the
    # bottom first and pushes the rest off the top (iTerm2, Prompt), 'top'
    # always pushes rows off the top.
    shrink: str = 'cursor'
    # Narrower or wider: rewrap soft-wrapped lines (most modern terminals) or
    # cut and pad rows (xterm).
    reflow: bool = False
    # Characters the terminal draws two cells wide although wcwidth says one
    # (iOS draws some emoji this way).
    wide: frozenset = field(default_factory=frozenset)
    # ED 2 (and ED 0 from the home position) pushes the screen into the
    # scrollback first (tmux, some terminals).
    ed2_push: bool = False
    # Lines scrolled out of a scroll region go to the scrollback: 'top0' only
    # when the region starts at the top row (xterm), 'any' always (tmux).
    region_sb: str = 'top0'
    # REP stops at the end of the line (tmux) instead of wrapping (xterm).
    rep_clamp: bool = False
    # Which rows stay joined (wrapped) through erases, line inserts and
    # deletes and region scrolls follows tmux's grid exactly
    # (grid_clear_lines, grid_move_lines, grid_scroll_history_region):
    # clearing whole rows ends the wrap of the row above them, moving rows
    # ends the wrap into where they land and into where they left, and a line
    # a region below the top row pushes into the scrollback only stays joined
    # to the next line the same region pushes. Without it, simpler rules: a
    # row's wrap goes with the row and an erase to its end ends it.
    tmux_grid: bool = False
    # A pending wrap puts the cursor one past the last column (tmux): a line
    # feed keeps the wrap pending, erases and edits there touch nothing, and
    # moves left count from one further right. xterm keeps the cursor on the
    # last column with a flag that any move clears.
    past_edge: bool = False
    # Inserting or deleting lines moves the cursor to the left margin (xterm).
    il_cr: bool = True
    # With autowrap off, writing the last column still leaves a wrap
    # pending for when autowrap is back on (Ghostty).
    nowrap_pending: bool = False
    # Draw the DEC special graphics set (ESC ( 0) as line-drawing characters;
    # off, keep the letters (what tmux's capture-pane shows).
    acs: bool = True
    # An erase, or inserting or deleting characters, in the line cancels a
    # pending wrap (Ghostty).
    erase_clears_pending: bool = False
    # An emoji skin-tone modifier is a character of its own, two cells wide
    # (Ghostty without grapheme clustering, mode 2027 off), not part of the
    # emoji before it (tmux).
    modifier_wide: bool = False
    # Each regional indicator (half of a flag) is two cells (Ghostty); tmux
    # draws the pair in two.
    regional_wide: bool = False
    # Erase characters and delete characters also end the cursor row's wrap
    # (Ghostty's cursorResetWrap; it does the same for EL 0 and EL 2).
    edit_unwraps: bool = False
    # Insert and delete lines with the cursor outside the scroll region:
    # 'ignore' them (DEC, xterm, Ghostty) or act on the rows from the cursor
    # to the bottom of the screen ('screen', tmux).
    il_outside: str = 'ignore'
    # Backspace at the first column goes back to the end of the row above
    # when that row wrapped (tmux always; xterm only with reverse-wrap, mode
    # 45).
    bs_reverse_wrap: bool = False
    # Rows shifted by insert/delete lines, scroll down, and scroll up in a
    # region below the top row all lose their wrap (Ghostty insertLines and
    # deleteLines); a line feed in such a region rotates rows and keeps it.
    shift_unwraps: bool = False

    def name(self):
        d = Quirks()
        parts = [f'{k}={getattr(self, k)}' for k in
                 ('wrap', 'grow', 'shrink', 'reflow', 'ed2_push',
                  'region_sb', 'rep_clamp', 'tmux_grid', 'past_edge',
                  'il_cr', 'nowrap_pending', 'acs', 'erase_clears_pending',
                  'shift_unwraps', 'modifier_wide', 'regional_wide',
                  'edit_unwraps', 'il_outside', 'bs_reverse_wrap')
                 if getattr(self, k) != getattr(d, k)]
        if self.wide:
            parts.append('wide=' + ''.join(sorted(self.wide)))
        return ','.join(parts) or 'xterm'


XTERM = Quirks()
PROMPT = Quirks(wrap='sticky', grow='pull', shrink='blankfirst', reflow=True)
ITERM = Quirks(grow='pull', shrink='blankfirst', reflow=True)
# Ghostty (libghostty-vt), checked by validate.py --ghostty.
GHOSTTY = Quirks(grow='pull', nowrap_pending=True, erase_clears_pending=True,
                 shift_unwraps=True, modifier_wide=True, regional_wide=True,
                 edit_unwraps=True)
# A tmux pane as a terminal (what validate.py checks the model against).
TMUXPANE = Quirks(ed2_push=True, region_sb='any', rep_clamp=True,
                  tmux_grid=True, past_edge=True, il_cr=False, acs=False,
                  il_outside='screen', bs_reverse_wrap=True)


ACS = dict(zip('`afgjklmnopqrstuvwxyz{|}~',
               '◆▒°±┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·'))


def cell_width(ch, q):
    if ch in q.wide:
        return 2
    o = ord(ch[0])
    if o < 0x20 or 0x7f <= o < 0xa0:
        return -1                       # control: not drawn at all
    if 0x1f1e6 <= o <= 0x1f1ff and q.regional_wide:
        return 2
    if 0x1f3fb <= o <= 0x1f3ff:
        return 2 if q.modifier_wide else 0   # skin tone
    if unicodedata.combining(ch[0]) or o in (0x200d, 0xfe0f, 0xfe0e) or \
            unicodedata.category(ch[0]) in ('Mn', 'Me', 'Cf'):
        return 0
    if unicodedata.east_asian_width(ch[0]) in ('W', 'F'):
        return 2
    return 1


class Screen:
    def __init__(self, cols, rows):
        self.rows = [[' '] * cols for _ in range(rows)]
        self.wrapped = [False] * rows

    def blank_row(self, cols):
        return [' '] * cols


class Term:
    def __init__(self, cols=80, rows=24, quirks=XTERM):
        self.c, self.r, self.q = cols, rows, quirks
        self.main = Screen(cols, rows)
        self.alt_screen = None          # Screen while the alternate is active
        self.sb = []                    # (text, wrapped) oldest first
        self.x = self.y = 0
        self.pending = False
        self.top, self.bot = 0, rows - 1
        self.autowrap = True
        self.saved = (0, 0)
        self.saved_main = None          # cursor saved by 1049
        self.tabs = set(range(0, 1000, 8))
        self.insert = False
        self.origin = False
        self.charset = {0: 'B', 1: 'B'}
        self.gl = 0
        self.rpush = None               # a region push waiting to rejoin
        self.last = ' '
        self.state = 'ground'
        self.buf = b''
        self.utf = b''
        self.events = []

    # -- screen access
    @property
    def scr(self):
        return self.alt_screen if self.alt_screen is not None else self.main

    def row_text(self, i, scr=None):
        scr = scr or self.scr
        return ''.join(ch for ch in scr.rows[i] if ch != '').rstrip()

    def blank(self):
        return [' '] * self.c

    # -- rows (tmux's grid primitives when tmux_grid is set)
    def _touch(self, py, ny):
        if self.rpush is not None and py <= self.rpush[0] < py + ny:
            self.rpush = None

    def _clear_lines(self, py, ny):
        s = self.scr
        self._touch(py, ny)
        if self.q.erase_clears_pending and py <= self.y < py + ny:
            self.pending = False
        for y in range(py, py + ny):
            s.rows[y] = self.blank()
            s.wrapped[y] = False
        if py > 0 and self.q.tmux_grid:
            s.wrapped[py - 1] = False

    def _clear(self, px, py, nx, ny):
        """Blank cells; whole rows go through _clear_lines."""
        if nx <= 0 or ny <= 0:
            return
        if self.q.erase_clears_pending and py <= self.y < py + ny:
            self.pending = False
        if px == 0 and nx >= self.c:
            return self._clear_lines(py, ny)
        s = self.scr
        self._touch(py, ny)
        a, b = max(0, px), min(self.c, px + nx)
        for y in range(py, py + ny):
            row = s.rows[y]
            # A wide character cut by the erase goes whole.
            if a > 0 and row[a] == '':
                row[a - 1] = ' '
            if b < self.c and row[b] == '':
                row[b] = ' '
            for k in range(a, b):
                row[k] = ' '
            if not self.q.tmux_grid and b >= self.c:
                s.wrapped[y] = False

    def _move_lines(self, dy, py, ny):
        """grid_move_lines: rows py..py+ny-1 to dy.., vacated rows emptied."""
        if ny == 0 or py == dy:
            return
        s = self.scr
        self._touch(dy, ny)
        self._touch(py, ny)
        if dy != 0 and self.q.tmux_grid:
            s.wrapped[dy - 1] = False
        rows = [s.rows[y] for y in range(py, py + ny)]
        wr = [s.wrapped[y] for y in range(py, py + ny)]
        for y in range(py, py + ny):
            if y < dy or y >= dy + ny:
                s.rows[y] = self.blank()
                s.wrapped[y] = False
        for i in range(ny):
            s.rows[dy + i] = rows[i]
            s.wrapped[dy + i] = wr[i] and not self.q.shift_unwraps
        if py != 0 and (py < dy or py >= dy + ny) and self.q.tmux_grid:
            s.wrapped[py - 1] = False

    def scroll_up(self, n=1, csi=False):
        n = min(n, self.bot - self.top + 1)
        if csi and self.q.shift_unwraps and self.top != 0:
            # Ghostty: SU in a region below the top row is delete lines at
            # the region's top.
            n = min(n, self.bot - self.top + 1)
            self._move_lines(self.top, self.top + n, self.bot + 1 - self.top - n)
            self._clear(0, self.bot + 1 - n, self.c, n)
            return
        for _ in range(n):
            self._scroll_up_one()

    def _scroll_up_one(self):
        s = self.scr
        top, bot = self.top, self.bot
        if self.alt_screen is None and top == 0 and bot == self.r - 1:
            self.sb.append((self.row_text(0), s.wrapped[0]))
            self.rpush = None
            del s.rows[0]
            del s.wrapped[0]
            s.rows.append(self.blank())
            s.wrapped.append(False)
            return
        if self.alt_screen is None and (top == 0 or self.q.region_sb == 'any'):
            if self.q.tmux_grid:
                # grid_scroll_history_region
                if top != 0 and self.sb:
                    keep = self.rpush is not None and \
                        self.rpush == (top, bot, True)
                    self.sb[-1] = (self.sb[-1][0], keep)
                self.rpush = (top, bot, s.wrapped[top])
                self.sb.append((self.row_text(top),
                                s.wrapped[top] and top == 0))
            else:
                self.sb.append((self.row_text(top), s.wrapped[top]))
            del s.rows[top]
            del s.wrapped[top]
            s.rows.insert(bot, self.blank())
            s.wrapped.insert(bot, False)
            return
        if self.q.tmux_grid:
            self._move_lines(top, top + 1, bot - top)
        else:
            del s.rows[top]
            del s.wrapped[top]
            s.rows.insert(bot, self.blank())
            s.wrapped.insert(bot, False)

    def scroll_down(self, n=1):
        s = self.scr
        n = min(n, self.bot - self.top + 1)
        for _ in range(n):
            self._move_lines(self.top + 1, self.top, self.bot - self.top)

    def insert_lines(self, n):
        y, top, bot = self.y, self.top, self.bot
        if (y < top or y > bot) and self.q.il_outside == 'ignore':
            return
        if y < top or y > bot:
            n = min(n, self.r - y)
            if n:
                self._move_lines(y + n, y, self.r - y - n)
        else:
            n = min(n, bot + 1 - y)
            if n:
                n2 = bot + 1 - y - n
                self._move_lines(bot + 1 - n2, y, n2)
                self._clear(0, y + n2, self.c, n - n2)
        if self.q.il_cr:
            self.x = 0
            self.pending = False

    def delete_lines(self, n):
        y, top, bot = self.y, self.top, self.bot
        if (y < top or y > bot) and self.q.il_outside == 'ignore':
            return
        if y < top or y > bot:
            n = min(n, self.r - y)
            if n:
                self._move_lines(y, y + n, self.r - y - n)
                self._clear(0, self.r - n, self.c, n)
        else:
            n = min(n, bot + 1 - y)
            if n:
                n2 = bot + 1 - y - n
                self._move_lines(y, y + n, n2)
                self._clear(0, y + n2, self.c, n - n2)
        if self.q.il_cr:
            self.x = 0
            self.pending = False

    def lf(self):
        if self.y == self.bot:
            self.scroll_up()
        elif self.y < self.r - 1:
            self.y += 1

    # -- printing
    def put(self, ch):
        w = cell_width(ch, self.q)
        s = self.scr
        if w < 0:
            return
        if w == 0:
            # Combining: attach to the cell before, or stand alone when there
            # is none (a skin tone alone is two cells, anything else one).
            px = self.x - 1 if not self.pending else self.x
            while px > 0 and s.rows[self.y][px] == '':
                px -= 1
            if 0 <= px < self.c and (px < self.x or self.pending):
                s.rows[self.y][px] += ch
                return
            w = 2 if 0x1f3fb <= ord(ch[0]) <= 0x1f3ff else 1
        if self.charset[self.gl] == '0' and self.q.acs:
            ch = ACS.get(ch, ch)
        self.last = ch
        if self.pending and self.autowrap:
            s.wrapped[self.y] = True
            self.x = 0
            self.lf()
            self.pending = False
        elif self.pending:
            self.pending = False
        if w == 2 and self.x == self.c - 1:
            if self.autowrap:
                s.rows[self.y][self.x] = ' '
                s.wrapped[self.y] = True
                self.x = 0
                self.lf()
            else:
                return
        s = self.scr
        self._touch(self.y, 1)
        # Overwriting half of a wide character blanks the other half: the
        # head when writing over its tail, the tail when writing over its head.
        row = s.rows[self.y]
        if row[self.x] == '' and self.x > 0:
            row[self.x - 1] = ' '
        end = self.x + w
        if end < self.c and row[end] == '':
            row[end] = ' '
        if self.insert:
            row = s.rows[self.y]
            for _ in range(w):
                row.insert(self.x, ' ')
            del row[self.c:]
        s.rows[self.y][self.x] = ch
        if w == 2:
            s.rows[self.y][self.x + 1] = ''
        self.x += w
        if self.x >= self.c:
            self.x = self.c - 1
            if not self.autowrap:
                if self.q.nowrap_pending:
                    self.pending = True
            elif self.q.wrap == 'eager':
                s.wrapped[self.y] = True
                self.x = 0
                self.lf()
            else:
                self.pending = True
        # A row written again no longer continues: only a wrap sets it.

    def move(self, x=None, y=None):
        if x is not None:
            self.x = max(0, min(self.c - 1, x))
        if y is not None:
            self.y = max(0, min(self.r - 1, y))
        if self.q.wrap != 'sticky':
            self.pending = False

    def at_edge(self):
        return self.pending and self.q.past_edge

    # -- erasing
    def erase_cells(self, y, a, b):
        self._clear(a, y, b - a, 1)

    def ed(self, n):
        s = self.scr
        if n == 0 and self.x == 0 and self.y == 0 and self.q.ed2_push and \
                not self.pending:
            return self.ed(2)
        if n == 0:
            if self.x == 0 and not self.pending:
                self._clear_lines(self.y, 1)
            elif not self.at_edge():
                self._clear(self.x, self.y, self.c - self.x, 1)
            if self.y + 1 < self.r:
                self._clear_lines(self.y + 1, self.r - self.y - 1)
        elif n == 1:
            if self.y > 0:
                self._clear_lines(0, self.y)
            if self.x >= self.c - 1:
                self._clear_lines(self.y, 1)
            else:
                self._clear(0, self.y, self.x + 1, 1)
        elif n == 2:
            if self.q.ed2_push and self.alt_screen is None:
                last = max([i for i in range(self.r) if self.row_text(i)] or [-1])
                for i in range(last + 1):
                    self.sb.append((self.row_text(i), s.wrapped[i]))
                self.rpush = None
            self._clear_lines(0, self.r)
        elif n == 3:
            self.sb = []
            self.rpush = None
            self.events.append('E3')

    # -- resize
    def resize(self, cols, rows):
        if cols != self.c:
            self._resize_cols(cols)
        if rows > self.r:
            self._grow(rows - self.r)
        elif rows < self.r:
            self._shrink(self.r - rows)
        self.r = rows
        self.top, self.bot = 0, rows - 1
        self.y = max(0, min(self.y, rows - 1))
        self.tabs = set(range(0, 1000, 8))

    def _grow(self, k):
        for scr in [self.main] + ([self.alt_screen] if self.alt_screen else []):
            pulled = 0
            if self.q.grow == 'pull' and scr is self.main:
                while pulled < k and self.sb:
                    text, wr = self.sb.pop()
                    scr.rows.insert(0, list(text.ljust(self.c)[:self.c]))
                    scr.wrapped.insert(0, wr)
                    pulled += 1
                if scr is self.scr:
                    self.y += pulled
                elif self.saved_main:
                    x, y = self.saved_main
                    self.saved_main = (x, y + pulled)
            for _ in range(k - pulled):
                scr.rows.append(self.blank())
                scr.wrapped.append(False)

    def _shrink(self, k):
        for scr in [self.main] + ([self.alt_screen] if self.alt_screen else []):
            cy = self.y if scr is self.scr else (self.saved_main or (0, 0))[1]
            n = len(scr.rows)
            new = n - k
            mode = self.q.shrink
            if mode == 'top':
                push = k
            elif mode == 'blankfirst':
                drop = 0
                while drop < k and n - 1 - drop > cy and \
                        not ''.join(scr.rows[n - 1 - drop]).strip():
                    drop += 1
                push = k - drop
                del scr.rows[n - drop:]
                del scr.wrapped[n - drop:]
            else:
                push = max(0, cy - new + 1)
            for _ in range(push):
                if scr is self.main:
                    self.sb.append((''.join(ch for ch in scr.rows[0]
                                            if ch != '').rstrip(),
                                    scr.wrapped[0]))
                del scr.rows[0]
                del scr.wrapped[0]
            del scr.rows[new:]
            del scr.wrapped[new:]
            if scr is self.scr:
                self.y = max(0, cy - push)
            elif self.saved_main:
                self.saved_main = (self.saved_main[0], max(0, cy - push))

    def _resize_cols(self, cols):
        if not self.q.reflow:
            for scr in [self.main] + ([self.alt_screen] if self.alt_screen else []):
                for i, row in enumerate(scr.rows):
                    scr.rows[i] = (row + [' '] * cols)[:cols]
                    if scr.rows[i] and scr.rows[i][-1] == '' :
                        scr.rows[i][-1] = ' '
            self.c = cols
            self.x = min(self.x, cols - 1)
            return
        # Reflow: join soft-wrapped lines of scrollback and main screen and
        # wrap them again. The cursor keeps its place in its logical line.
        lines = []          # logical lines: [text, cursor_offset or None]
        cur = None
        def add(text, wrapped, is_cursor_row=False):
            nonlocal cur
            if lines and lines[-1][2]:
                lines[-1][0] += text
                if is_cursor_row:
                    cur = (len(lines) - 1, lines[-1][3] + self.x)
                lines[-1][3] += self.c
                lines[-1][2] = wrapped
            else:
                lines.append([text, None, wrapped, self.c])
                if is_cursor_row:
                    cur = (len(lines) - 1, self.x)
        for text, wr in self.sb:
            add(text.ljust(self.c) if wr else text, wr)
        m = self.main
        last = max([i for i in range(self.r) if self.row_text(i, m)] +
                   [self.y if self.alt_screen is None else 0])
        for i in range(last + 1):
            full = ''.join(ch for ch in m.rows[i] if ch != '')
            add(full if m.wrapped[i] else full.rstrip(), m.wrapped[i],
                self.alt_screen is None and i == self.y)
        phys = []           # (text, wrapped)
        cpos = None
        for li, (text, _, _, _) in enumerate(lines):
            text = text.rstrip() if True else text
            chunks = [text[j:j + cols] for j in range(0, max(len(text), 1), cols)] or ['']
            if cur and cur[0] == li:
                off = cur[1]
                cpos = (len(phys) + min(off // cols, len(chunks) - 1 if off // cols >= len(chunks) and off % cols == 0 and off else off // cols), off % cols)
                if off // cols >= len(chunks):
                    chunks += [''] * (off // cols - len(chunks) + 1)
                    cpos = (len(phys) + off // cols, off % cols)
            for j, ch in enumerate(chunks):
                phys.append((ch, j < len(chunks) - 1))
        self.c = cols
        cy = cpos[0] if cpos else len(phys) - 1
        start = max(0, max(len(phys), cy + 1) - self.r)
        self.sb = phys[:start]
        m.rows = [list(t.ljust(cols)[:cols]) for t, _ in phys[start:start + self.r]]
        m.wrapped = [w for _, w in phys[start:start + self.r]]
        while len(m.rows) < self.r:
            m.rows.append(self.blank()); m.wrapped.append(False)
        if self.alt_screen is None:
            self.y = cy - start
            self.x = min(cpos[1] if cpos else 0, cols - 1)
        if self.alt_screen is not None:
            a = self.alt_screen
            for i, row in enumerate(a.rows):
                a.rows[i] = (row + [' '] * cols)[:cols]
            self.x = min(self.x, cols - 1)

    def hidden_shift(self, k):
        """The terminal grows by k rows and shrinks back before anyone is told
        (a phone keyboard animating): what is left depends on the quirks."""
        r = self.r
        self.resize(self.c, r + k)
        self.resize(self.c, r)

    # -- modes
    def set_mode(self, private, params, on):
        for p in params:
            if private and p in (47, 1047, 1049):
                if on and self.alt_screen is None:
                    if p == 1049:
                        self.saved_main = (self.x, self.y)
                    self.alt_screen = Screen(self.c, self.r)
                    self.events.append('ALT+')
                    if p == 1049:
                        pass
                elif not on and self.alt_screen is not None:
                    self.alt_screen = None
                    self.events.append('ALT-')
                    if p == 1049 and self.saved_main:
                        self.x, self.y = self.saved_main
                        self.saved_main = None
                self.pending = False
            elif private and p == 7:
                self.autowrap = on
            elif private and p == 6:
                self.origin = on
                self.move(0, self.top if on else 0)
            elif not private and p == 4:
                self.insert = on
            elif private and p in (1000, 1002, 1003, 1006, 1005, 1015):
                self.events.append(('mouse+' if on else 'mouse-') + str(p))
            elif private and p == 1004:
                self.events.append('focus+' if on else 'focus-')
            elif private and p == 2004:
                self.events.append('paste+' if on else 'paste-')

    # -- parser
    def feed(self, data):
        for b in data:
            self._byte(b)

    def _byte(self, b):
        st = self.state
        if st == 'ground':
            if self.utf:
                self.utf += bytes([b])
                need = 4 if self.utf[0] >= 0xf0 else 3 if self.utf[0] >= 0xe0 else 2
                if len(self.utf) >= need or b < 0x80 or b >= 0xc0:
                    try:
                        ch = self.utf.decode('utf-8')
                    except UnicodeDecodeError:
                        ch = '�'
                    self.utf = b''
                    self.put(ch)
                return
            if b == 0x1b:
                self.state = 'esc'; self.buf = b''
            elif b >= 0xc0:
                self.utf = bytes([b])
            elif b >= 0x80:
                pass
            elif b >= 0x20 and b != 0x7f:
                self.put(chr(b))
            else:
                self._ctrl(b)
        elif st == 'esc':
            if b == ord('['):
                self.state = 'csi'; self.buf = b''
            elif b == ord(']'):
                self.state = 'osc'; self.buf = b''
            elif b in (ord('P'), ord('X'), ord('^'), ord('_')):
                self.state = 'dcs'; self.buf = b''
            elif b in (ord('('), ord(')'), ord('*'), ord('+'), ord('#'), ord('%')):
                self.state = 'charset'
                self.buf = bytes([b])
            else:
                self.state = 'ground'
                self._esc(b)
        elif st == 'charset':
            if self.buf in (b'(', b')'):
                self.charset[0 if self.buf == b'(' else 1] = chr(b)
            self.state = 'ground'
        elif st == 'csi':
            if 0x40 <= b <= 0x7e:
                self.state = 'ground'
                self._csi(self.buf, chr(b))
            elif b == 0x1b:
                self.state = 'esc'
            elif b < 0x20:
                self._ctrl(b)
            else:
                self.buf += bytes([b])
        elif st in ('osc', 'dcs'):
            if b == 0x07 and st == 'osc':
                self.state = 'ground'
            elif b == 0x1b:
                self.state = st + '-esc'
            else:
                self.buf += bytes([b])
        elif st in ('osc-esc', 'dcs-esc'):
            if b == ord('\\'):
                self.state = 'ground'
            else:
                self.state = st[:-4]

    def _ctrl(self, b):
        if b == 0x0e:
            self.gl = 1
        elif b == 0x0f:
            self.gl = 0
        elif b == 0x0d:
            self.x = 0; self.pending = False
        elif b in (0x0a, 0x0b, 0x0c):
            if self.q.wrap != 'sticky' and not self.q.past_edge:
                self.pending = False
            self.lf()
        elif b == 0x08:
            if self.pending and self.q.past_edge:
                self.pending = False
                return
            if self.pending and self.q.wrap != 'sticky':
                self.pending = False
            if self.x == 0 and self.y > 0 and self.q.bs_reverse_wrap and \
                    self.scr.wrapped[self.y - 1]:
                self.y -= 1
                self.x = self.c - 1
                return
            self.x = max(0, self.x - 1)
        elif b == 0x09:
            nxt = [t for t in sorted(self.tabs) if t > self.x]
            self.x = min(self.c - 1, nxt[0] if nxt else self.c - 1)
            if self.q.wrap != 'sticky':
                self.pending = False

    def _esc(self, b):
        c = chr(b)
        if (c in 'DM' and self.q.wrap != 'sticky' and not self.q.past_edge) or \
                c == 'E':
            self.pending = False
        if c == '7':
            self.saved = (self.x, self.y)
        elif c == '8':
            self.move(*self.saved)
        elif c == 'D':
            self.lf()
        elif c == 'E':
            self.x = 0; self.lf()
        elif c == 'M':
            if self.y == self.top:
                self.scroll_down()
            elif self.y > 0:
                self.y -= 1
        elif c == 'c':
            self.__init__(self.c, self.r, self.q)
        elif c == 'H':
            self.tabs.add(self.x)

    def _csi(self, raw, f):
        private = raw[:1] in (b'?', b'>', b'<', b'=')
        body = raw[1:] if private else raw
        if b'$' in body or b' ' in body or b'"' in body or b"'" in body:
            return
        try:
            ps = [int(x) if x else 0 for x in body.decode().split(';')] if body else []
        except ValueError:
            return
        a = ps[0] if ps else 0
        n = a or 1
        if raw[:1] == b'?':
            if f in 'hl':
                self.set_mode(True, ps, f == 'h')
            return
        if not private and f in 'hl':
            self.set_mode(False, ps, f == 'h')
            return
        if private:
            return
        s = self.scr
        if f in 'Hf':
            y = n - 1
            if self.origin:
                y = min(self.bot, self.top + y)
            self.move((ps[1] if len(ps) > 1 and ps[1] else 1) - 1, y)
        elif f == 'A':
            self.move(None, max(self.top if self.y >= self.top else 0, self.y - n))
        elif f == 'B':
            self.move(None, min(self.bot if self.y <= self.bot else self.r - 1, self.y + n))
        elif f == 'C':
            self.move(min(self.c - 1, self.x + n))
        elif f == 'D':
            self.move(max(0, self.x + (1 if self.at_edge() else 0) - n))
        elif f == 'E':
            self.move(0, min(self.bot, self.y + n))
        elif f == 'F':
            self.move(0, max(self.top, self.y - n))
        elif f in 'G`':
            self.move(n - 1)
        elif f == 'd':
            self.move(None, n - 1)
        elif f == 'J':
            self.ed(a)
        elif f == 'K':
            if a == 0:
                if self.x == 0 and not self.pending:
                    self._clear_lines(self.y, 1)
                elif not self.at_edge():
                    self._clear(self.x, self.y, self.c - self.x, 1)
            elif a == 1:
                if self.x >= self.c - 1:
                    self._clear_lines(self.y, 1)
                else:
                    self._clear(0, self.y, self.x + 1, 1)
            else:
                self._clear_lines(self.y, 1)
        elif f == 'X':
            if self.q.edit_unwraps:
                self.scr.wrapped[self.y] = False
            if not self.at_edge():
                self.erase_cells(self.y, self.x, self.x + n)
            if self.x + n < self.c:
                pass
        elif f in 'P@' and self.pending and self.q.erase_clears_pending:
            self.pending = False
            self._csi(raw, f)
        elif f == 'P' and not self.at_edge():
            if self.q.edit_unwraps:
                s.wrapped[self.y] = False
            row = s.rows[self.y]
            del row[self.x:self.x + n]
            row.extend([' '] * (self.c - len(row)))
        elif f == '@' and not self.at_edge():
            row = s.rows[self.y]
            for _ in range(n):
                row.insert(self.x, ' ')
            del row[self.c:]
        elif f == 'L':
            self.insert_lines(n)
        elif f == 'M':
            self.delete_lines(n)
        elif f == 'S':
            self.scroll_up(n, csi=True)
        elif f == 'T':
            self.scroll_down(n)
        elif f == 'r':
            t = (ps[0] if ps and ps[0] else 1) - 1
            bt = (ps[1] if len(ps) > 1 and ps[1] else self.r) - 1
            if t < bt < self.r:
                self.top, self.bot = t, bt
                self.move(0, t if self.origin else 0)
                self.pending = False
        elif f == 's':
            self.saved = (self.x, self.y)
        elif f == 'u':
            self.move(*self.saved)
        elif f == 'b':
            if self.q.rep_clamp:
                n = min(n, self.c - self.x)
            for _ in range(n):
                self.put(self.last)
        elif f == 'g':
            if a == 0:
                self.tabs.discard(self.x)
            elif a == 3:
                self.tabs = set()
        elif f == 'I':
            for _ in range(n):
                self._ctrl(0x09)
        elif f == 'Z':
            for _ in range(n):
                prev = [t for t in sorted(self.tabs) if t < self.x]
                self.move(prev[-1] if prev else 0)
        elif f in 'hl':
            pass

    # -- results
    def lines(self):
        """Scrollback then main screen, as (text, wrapped) with trailing blank
        rows below the cursor and the last text dropped."""
        out = list(self.sb)
        m = self.main
        for i in range(self.r):
            out.append((self.row_text(i, m), m.wrapped[i]))
        return out

    def state_of(self):
        return {'lines': self.lines(), 'alt': self.alt_screen is not None,
                'alt_rows': [self.row_text(i) for i in range(self.r)]
                if self.alt_screen is not None else None,
                'cursor': (min(self.x, self.c - 1), self.y)}
