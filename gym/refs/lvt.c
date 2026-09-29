/*
 * lvt: feed a byte stream to libvterm (the terminal inside Neovim and Vim) and
 * print what it holds, in gvt's format.
 *
 *   lvt COLS ROWS STREAM [EVENTS]
 *
 * EVENTS: "OFFSET resize COLS ROWS" or "OFFSET hidden K", as for gvt.
 * libvterm keeps no scrollback itself: rows it pushes off the top are kept
 * here (sb_pushline) and given back when it grows (sb_popline), with each
 * row's "continues the row above" flag taken as the row goes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vterm.h>

#define MAXSB 200000

struct line {
	char	*text;
	int	 wraps;	/* wraps on to the line after */
	int	 cols;
	VTermScreenCell *cells;
};

static struct line	 sb[MAXSB];
static int		 nsb;
static VTermState	*state;

static int
utf8(uint32_t c, char *out)
{
	if (c < 0x80) { out[0] = c; return 1; }
	if (c < 0x800) { out[0] = 0xc0 | (c >> 6); out[1] = 0x80 | (c & 0x3f); return 2; }
	if (c < 0x10000) { out[0] = 0xe0 | (c >> 12); out[1] = 0x80 | ((c >> 6) & 0x3f);
		out[2] = 0x80 | (c & 0x3f); return 3; }
	out[0] = 0xf0 | (c >> 18); out[1] = 0x80 | ((c >> 12) & 0x3f);
	out[2] = 0x80 | ((c >> 6) & 0x3f); out[3] = 0x80 | (c & 0x3f); return 4;
}

static char *
cells_text(int cols, const VTermScreenCell *cells)
{
	char	*s = malloc(cols * 4 * VTERM_MAX_CHARS_PER_CELL + 1);
	int	 n = 0, i, j, end = 0;

	for (i = 0; i < cols; i++) {
		if (cells[i].chars[0] == (uint32_t)-1)
			continue;	/* right half of a wide character */
		if (cells[i].chars[0] == 0) {
			s[n++] = ' ';
			continue;
		}
		for (j = 0; j < VTERM_MAX_CHARS_PER_CELL && cells[i].chars[j]; j++)
			n += utf8(cells[i].chars[j], s + n);
		end = n;
	}
	s[end] = '\0';
	return s;
}

/*
 * libvterm moves its line info up before it asks for the row to be pushed, so
 * row 0's "continuation" now says whether the row after this one continues
 * it: whether this one wraps.
 */
static int
pushline(int cols, const VTermScreenCell *cells, void *user)
{
	const VTermLineInfo *li = vterm_state_get_lineinfo(state, 0);

	(void)user;
	if (nsb == MAXSB)
		return 0;
	sb[nsb].text = cells_text(cols, cells);
	sb[nsb].wraps = li != NULL && li->continuation;
	sb[nsb].cols = cols;
	sb[nsb].cells = malloc(cols * sizeof *cells);
	memcpy(sb[nsb].cells, cells, cols * sizeof *cells);
	nsb++;
	return 1;
}

static int
popline(int cols, VTermScreenCell *cells, void *user)
{
	int	 i;

	(void)user;
	if (nsb == 0)
		return 0;
	nsb--;
	for (i = 0; i < cols; i++) {
		if (i < sb[nsb].cols)
			cells[i] = sb[nsb].cells[i];
		else {
			memset(&cells[i], 0, sizeof cells[i]);
			cells[i].width = 1;
		}
	}
	free(sb[nsb].text);
	free(sb[nsb].cells);
	return 1;
}

static int
sbclear(void *user)
{
	(void)user;
	while (nsb > 0) {
		nsb--;
		free(sb[nsb].text);
		free(sb[nsb].cells);
	}
	return 1;
}

static VTermScreenCallbacks cbs = {
	.sb_pushline = pushline,
	.sb_popline = popline,
	.sb_clear = sbclear,
};

int
main(int argc, char **argv)
{
	VTerm		*vt;
	VTermScreen	*screen;
	FILE		*f, *ev = NULL;
	char		*data, line[256], op[32];
	long		 size, at = 0, off;
	int		 cols, rows, a, b, r, c, i, first;
	VTermPos	 pos;
	VTermScreenCell	*cells;
	char		**text;
	int		*cont;

	if (argc < 4) {
		fprintf(stderr, "usage: lvt COLS ROWS STREAM [EVENTS]\n");
		return 2;
	}
	cols = atoi(argv[1]);
	rows = atoi(argv[2]);
	if ((f = fopen(argv[3], "rb")) == NULL)
		return 1;
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	data = malloc(size + 1);
	if (fread(data, 1, size, f) != (size_t)size)
		return 1;
	fclose(f);
	if (argc > 4 && (ev = fopen(argv[4], "r")) == NULL)
		return 1;

	vt = vterm_new(rows, cols);
	vterm_set_utf8(vt, 1);
	screen = vterm_obtain_screen(vt);
	state = vterm_obtain_state(vt);
	vterm_screen_set_callbacks(screen, &cbs, NULL);
	vterm_screen_enable_altscreen(screen, 1);
	vterm_screen_enable_reflow(screen, true);
	vterm_screen_reset(screen, 1);

	while (ev != NULL && fgets(line, sizeof line, ev) != NULL) {
		a = b = 0;
		if (sscanf(line, "%ld %31s %d %d", &off, op, &a, &b) < 2)
			continue;
		if (off > size)
			off = size;
		if (off > at) {
			vterm_input_write(vt, data + at, off - at);
			at = off;
		}
		if (strcmp(op, "resize") == 0) {
			cols = a;
			rows = b;
			vterm_set_size(vt, rows, cols);
		} else if (strcmp(op, "hidden") == 0) {
			vterm_set_size(vt, rows + a, cols);
			vterm_set_size(vt, rows, cols);
		}
		vterm_screen_flush_damage(screen);
	}
	if (at < size)
		vterm_input_write(vt, data + at, size - at);
	vterm_screen_flush_damage(screen);

	/* Screen rows. */
	cells = calloc(cols, sizeof *cells);
	text = calloc(rows, sizeof *text);
	cont = calloc(rows, sizeof *cont);
	for (r = 0; r < rows; r++) {
		pos.row = r;
		for (c = 0; c < cols; c++) {
			pos.col = c;
			vterm_screen_get_cell(screen, pos, &cells[c]);
			if (c > 0 && cells[c - 1].width == 2)
				cells[c].chars[0] = (uint32_t)-1;
		}
		text[r] = cells_text(cols, cells);
		cont[r] = vterm_state_get_lineinfo(state, r)->continuation;
	}

	printf("@@rows\n");
	for (i = 0; i < nsb; i++)
		printf("%s\n", sb[i].text);
	for (r = 0; r < rows; r++)
		printf("%s\n", text[r]);
	printf("@@joined\n");
	first = 1;
	for (i = 0; i < nsb + rows; i++) {
		const char	*t = i < nsb ? sb[i].text : text[i - nsb];
		/* Does the line before this one wrap on to it? */
		int		 k;

		if (i == 0)
			k = 0;
		else if (i - 1 < nsb)
			k = sb[i - 1].wraps;
		else
			k = cont[i - nsb];
		if (!first && !k)
			putchar('\n');
		fputs(t, stdout);
		first = 0;
	}
	putchar('\n');
	vterm_state_get_cursorpos(state, &pos);
	printf("@@cursor %d %d 0 0\n", pos.col, pos.row);
	return 0;
}
