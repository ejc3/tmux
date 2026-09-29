/*
 * gvt: feed a byte stream to Ghostty's terminal (libghostty-vt) and print what
 * it holds, for gym/ to compare with its model and with tmux.
 *
 *   gvt COLS ROWS PULL STREAM [EVENTS]
 *
 * PULL is 1 to let a taller terminal pull rows back from the scrollback (the
 * default in Ghostty), 0 not to. EVENTS has one event per line, applied when
 * the stream reaches OFFSET bytes:
 *
 *   OFFSET resize COLS ROWS    the terminal is resized
 *   OFFSET hidden K            the terminal grows K rows and shrinks back
 *
 * Output: "@@rows" then every row of scrollback and screen, "@@joined" then
 * the same with soft-wrapped rows joined, and "@@cursor X Y PENDING SCREEN".
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

static bool
out(void *userdata, const uint8_t *data, size_t len)
{
	(void)userdata;
	return fwrite(data, 1, len, stdout) == len;
}

static void
dump(GhosttyTerminal t, bool unwrap)
{
	GhosttyFormatterTerminalOptions o =
	    GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
	GhosttyFormatter f;
	GhosttyWriter w = { .write = out, .userdata = NULL };

	o.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	o.unwrap = unwrap;
	o.trim = true;
	if (ghostty_formatter_terminal_new(NULL, &f, t, o) != GHOSTTY_SUCCESS) {
		fprintf(stderr, "gvt: formatter failed\n");
		exit(1);
	}
	ghostty_formatter_format(f, w);
	ghostty_formatter_free(f);
	putchar('\n');
}

static uint16_t
get16(GhosttyTerminal t, int what)
{
	uint16_t v = 0;

	ghostty_terminal_get(t, what, &v);
	return v;
}

int
main(int argc, char **argv)
{
	GhosttyTerminal	 t;
	FILE		*f, *ev = NULL;
	uint8_t		*data;
	long		 size, at = 0, off;
	char		 line[256], op[32];
	int		 cols, rows, pull, a, b;
	bool		 pb, pending = false;
	size_t		 max = 1000000;
	int		 screen = 0;

	if (argc < 5) {
		fprintf(stderr, "usage: gvt COLS ROWS PULL STREAM [EVENTS]\n");
		return 2;
	}
	cols = atoi(argv[1]);
	rows = atoi(argv[2]);
	pull = atoi(argv[3]);
	if ((f = fopen(argv[4], "rb")) == NULL) {
		perror(argv[4]);
		return 1;
	}
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	data = malloc(size + 1);
	if (fread(data, 1, size, f) != (size_t)size)
		return 1;
	fclose(f);
	if (argc > 5 && (ev = fopen(argv[5], "r")) == NULL) {
		perror(argv[5]);
		return 1;
	}

	if (ghostty_terminal_new(NULL, &t, cols, rows) != GHOSTTY_SUCCESS)
		return 1;
	pb = pull != 0;
	ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK, &pb);
	ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &max);

	while (ev != NULL && fgets(line, sizeof line, ev) != NULL) {
		a = b = 0;
		if (sscanf(line, "%ld %31s %d %d", &off, op, &a, &b) < 2)
			continue;
		if (off > size)
			off = size;
		if (off > at) {
			ghostty_terminal_vt_write(t, data + at, off - at);
			at = off;
		}
		if (strcmp(op, "resize") == 0) {
			cols = a;
			rows = b;
			ghostty_terminal_resize(t, cols, rows, 8, 16);
		} else if (strcmp(op, "hidden") == 0) {
			ghostty_terminal_resize(t, cols, rows + a, 8, 16);
			ghostty_terminal_resize(t, cols, rows, 8, 16);
		}
	}
	if (at < size)
		ghostty_terminal_vt_write(t, data + at, size - at);

	printf("@@rows\n");
	dump(t, false);
	printf("@@joined\n");
	dump(t, true);
	ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending);
	ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
	printf("@@cursor %u %u %d %d\n",
	    get16(t, GHOSTTY_TERMINAL_DATA_CURSOR_X),
	    get16(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y), pending ? 1 : 0, screen);
	ghostty_terminal_free(t);
	free(data);
	return 0;
}
