/* $OpenBSD$ */

/*
 * Copyright (c) 2026 ejc3 <ejc3@users.noreply.github.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Forwarding: with clear-on-attach off, when a client shows one pane and that
 * pane is the whole terminal, the pane's output is written to the terminal
 * as the program wrote it instead of being drawn from the grid. The terminal
 * then does with each sequence exactly what it would do with the program run
 * directly - its own wrapping, widths, scrollback and resize behaviour -
 * where drawing from the grid gives tmux's own reading of the sequences.
 *
 * The grid is still kept, and drawing from it takes over again (with a full
 * redraw) whenever the client stops qualifying: another pane, a floating
 * pane, a menu, a prompt, a mode, a status line, a blocked terminal.
 *
 * Two kinds of sequence are not written. Those the terminal answers (device
 * attributes, cursor and mode reports, colour queries): tmux answers them
 * already, and a second answer would arrive as the program's input. And the
 * modes tmux sets on the terminal itself from the pane's state (mouse, focus,
 * paste, keypad, cursor keys, cursor style, titles, clipboard): tmux keeps
 * setting those as before.
 */

/* The modes tmux sets on the terminal itself from the pane's state. */
static int
forward_managed_mode(int v)
{
	switch (v) {
	case 1:		/* cursor keys */
	case 12:	/* cursor blink */
	case 25:	/* cursor shown */
	case 1000:	/* mouse */
	case 1002:
	case 1003:
	case 1004:	/* focus */
	case 1005:
	case 1006:
	case 1015:
	case 1016:
	case 1036:	/* meta and alt keys */
	case 1039:
	case 2004:	/* bracketed paste */
	case 2027:	/* grapheme clusters */
	case 2031:	/* colour scheme reports */
	case 2048:	/* size reports */
		return (1);
	}
	return (0);
}

/*
 * Write a sequence to out unless it is one that is not forwarded; a DECSET or
 * DECRST mixing both kinds is written with only the modes tmux leaves alone.
 */
/* Write a colour in SGR parameters as the terminal can show it. */
static void
forward_colour(struct tty *tty, struct evbuffer *out, int *first, int kind,
    int colour)
{
	u_char	r, g, b;
	u_int	colours;
	int	c = colour;

	if (kind == 58 && !tty_term_has(tty->term, TTYC_SETULC) &&
	    !tty_term_has(tty->term, TTYC_SETULC1))
		return;				/* no underline colour */
	if ((c & COLOUR_FLAG_RGB) && (~tty->term->flags & TERM_RGBCOLOURS)) {
		colour_split_rgb(c, &r, &g, &b);
		c = colour_find_rgb(r, g, b);
	}
	if (tty->term->flags & TERM_256COLOURS)
		colours = 256;
	else
		colours = tty_term_number(tty->term, TTYC_COLORS);
	if ((c & COLOUR_FLAG_256) && colours < 256 && kind != 58) {
		c = colour_256to16(c);
		if (c & 8) {
			c &= 7;
			if (colours >= 16) {
				evbuffer_add_printf(out, "%s%d", *first ? "" : ";",
				    (kind == 38 ? 90 : 100) + c);
				*first = 0;
				return;
			}
		}
		evbuffer_add_printf(out, "%s%d", *first ? "" : ";",
		    (kind == 38 ? 30 : 40) + (c & 7));
		*first = 0;
		return;
	}
	if (c & COLOUR_FLAG_RGB) {
		colour_split_rgb(c, &r, &g, &b);
		evbuffer_add_printf(out, "%s%d;2;%u;%u;%u", *first ? "" : ";",
		    kind, r, g, b);
	} else
		evbuffer_add_printf(out, "%s%d;5;%d", *first ? "" : ";", kind,
		    c & 0xff);
	*first = 0;
}

/*
 * Write SGR as the terminal can show it, as tmux's own drawing would: RGB
 * colours on a terminal without them as the nearest of 256, 256 as 16 where
 * there are only 16 or 8, styled underlines as plain ones and no underline
 * colour where the terminal has neither.
 */
static void
forward_sgr(struct tty *tty, const u_char *s, size_t n, struct evbuffer *out)
{
	char	 params[512], *field[64], *sub[8], *cp;
	u_int	 nf = 0, ns, i, j;
	int	 first = 1, v, kind, smulx;

	if (n - 3 >= sizeof params) {
		evbuffer_add(out, s, n);
		return;
	}
	memcpy(params, s + 2, n - 3);
	params[n - 3] = '\0';
	for (cp = params; nf < nitems(field); ) {
		field[nf++] = cp;
		if ((cp = strchr(cp, ';')) == NULL)
			break;
		*cp++ = '\0';
	}
	smulx = tty_term_has(tty->term, TTYC_SMULX);

	evbuffer_add(out, "\033[", 2);
	for (i = 0; i < nf; i++) {
		if (strchr(field[i], ':') != NULL) {
			ns = 0;
			for (cp = field[i]; ns < nitems(sub); ) {
				sub[ns++] = cp;
				if ((cp = strchr(cp, ':')) == NULL)
					break;
				*cp++ = '\0';
			}
			kind = atoi(sub[0]);
			if (kind == 4 && !smulx) {
				evbuffer_add_printf(out, "%s%d", first ? "" : ";",
				    (ns > 1 && atoi(sub[1]) == 0) ? 24 : 4);
				first = 0;
				continue;
			}
			if ((kind == 38 || kind == 48 || kind == 58) && ns >= 3 &&
			    atoi(sub[1]) == 5) {
				forward_colour(tty, out, &first, kind,
				    atoi(sub[2]) | COLOUR_FLAG_256);
				continue;
			}
			if ((kind == 38 || kind == 48 || kind == 58) && ns >= 5 &&
			    atoi(sub[1]) == 2) {
				j = ns - 3;		/* last three: r:g:b */
				forward_colour(tty, out, &first, kind,
				    colour_join_rgb(atoi(sub[j]), atoi(sub[j + 1]),
				    atoi(sub[j + 2])));
				continue;
			}
			/* Anything else written back as it was. */
			evbuffer_add_printf(out, "%s", first ? "" : ";");
			for (j = 0; j < ns; j++)
				evbuffer_add_printf(out, "%s%s", j ? ":" : "", sub[j]);
			first = 0;
			continue;
		}
		v = atoi(field[i]);
		if ((v == 38 || v == 48 || v == 58) && i + 2 < nf &&
		    atoi(field[i + 1]) == 5) {
			forward_colour(tty, out, &first, v,
			    atoi(field[i + 2]) | COLOUR_FLAG_256);
			i += 2;
			continue;
		}
		if ((v == 38 || v == 48 || v == 58) && i + 4 < nf &&
		    atoi(field[i + 1]) == 2) {
			forward_colour(tty, out, &first, v,
			    colour_join_rgb(atoi(field[i + 2]), atoi(field[i + 3]),
			    atoi(field[i + 4])));
			i += 4;
			continue;
		}
		evbuffer_add_printf(out, "%s%s", first ? "" : ";", field[i]);
		first = 0;
	}
	evbuffer_add(out, "m", 1);
}

/*
 * OSC 66 for a terminal without it: the text, or for a width the text in
 * that many cells, as tmux draws it.
 */
static void
forward_sized(struct tty *tty, const u_char *s, size_t n, struct evbuffer *out)
{
	struct grid_cell	 gc;
	struct utf8_data	 ud;
	char			*copy, buf[TTY_SIZED_SIZE];
	const char		*text;
	u_int			 w;

	if (n != 0 && s[n - 1] == '\007')
		n--;
	else if (n >= 2 && s[n - 2] == '\033' && s[n - 1] == '\\')
		n -= 2;
	if (n < 5 || s[4] != ';')
		return;
	copy = xstrndup((const char *)s + 5, n - 5);
	if ((text = input_sized_parse(copy, &w)) == NULL || w > tty->sx)
		goto out;
	if (w == 0) {
		while (*text != '\0') {
			if (utf8_next(&text, &ud))
				evbuffer_add(out, ud.data, ud.size);
		}
		goto out;
	}
	memcpy(&gc, &grid_default_cell, sizeof gc);
	if (input_sized_data(text, w, &gc.data)) {
		gc.attr |= GRID_ATTR_SIZED;
		evbuffer_add(out, buf, tty_sized_cell(tty, &gc, buf,
		    sizeof buf));
		if (w > UTF8_MAXWIDTH)
			evbuffer_add(out, " ", 1);
	}
out:
	free(copy);
}

static void
forward_sequence(struct tty *tty, const u_char *s, size_t n,
    struct evbuffer *out)
{
	const u_char	*p;
	u_char		 final, lead;
	char		 keep[512];
	size_t		 kept;
	int		 v, have, all = 1;

	if (n < 2 || s[0] != '\033')
		goto write;
	switch (s[1]) {
	case '=':					/* keypad */
	case '>':
	case 'Z':					/* DECID */
		return;
	case ']':					/* OSC */
		v = 0;
		for (p = s + 2; p < s + n && *p >= '0' && *p <= '9'; p++)
			v = v * 10 + (*p - '0');
		switch (v) {
		case 0:					/* titles */
		case 1:
		case 2:
		case 52:				/* clipboard */
			return;
		case 8:					/* hyperlinks */
			if (!tty_term_has(tty->term, TTYC_HLS))
				return;
			break;
		case 4:					/* colour queries */
		case 10:
		case 11:
		case 12:
		case 17:
		case 19:
			if (memchr(s, '?', n) != NULL)
				return;
			break;
		case 22:				/* pointer shape */
			return;			/* tmux sets it itself */
		case 9:					/* notifications */
		case 99:
		case 777:
			return;			/* tmux passes them on */
		case 66:				/* text sizing */
			if (~tty->term->flags & TERM_TEXTSIZE) {
				forward_sized(tty, s, n, out);
				return;
			}
			break;
		}
		goto write;
	case '_':					/* APC */
		if (n > 4 && s[2] == 'G' && s[4] == '=')
			return;			/* tmux has the images */
		goto write;
	case 'P':					/* DCS */
		if (n > 3 && (s[2] == '$' || s[2] == '+'))	/* DECRQSS, XTGETTCAP */
			return;
		if (n > 6 && memcmp(s + 2, "tmux;", 5) == 0)	/* passthrough */
			return;
		goto write;
	case '[':
		break;
	default:
		goto write;
	}

	/* CSI. */
	final = s[n - 1];
	lead = (n > 2 && s[2] >= '<' && s[2] <= '?') ? s[2] : 0;
	switch (final) {
	case 'c':					/* DA1, DA2, DA3 */
	case 'n':					/* DSR, CPR, colour scheme */
	case 't':					/* window reports and moves */
		return;
	case 'p':
		if (memchr(s, '$', n) != NULL)		/* DECRQM */
			return;
		goto write;
	case 'q':					/* XTVERSION, DECSCUSR */
		if (lead == '>' || memchr(s, ' ', n) != NULL)
			return;
		goto write;
	case 'u':					/* kitty keyboard */
		if (lead != 0)
			return;
		goto write;
	case 'm':
		if (lead == '>')			/* XTMODKEYS */
			return;
		if (lead == 0) {
			forward_sgr(tty, s, n, out);
			return;
		}
		goto write;
	case 'h':
	case 'l':
		if (lead != '?')
			goto write;
		break;
	default:
		goto write;
	}

	/* DECSET or DECRST: keep the modes tmux does not set itself. */
	kept = 0;
	v = 0;
	have = 0;
	for (p = s + 3; p < s + n; p++) {
		if (*p >= '0' && *p <= '9') {
			v = v * 10 + (*p - '0');
			have = 1;
			continue;
		}
		if (*p != ';' && p != s + n - 1)
			goto write;			/* not understood */
		if (have && !forward_managed_mode(v) &&
		    (v != 2026 || tty_term_has(tty->term, TTYC_SYNC))) {
			kept += xsnprintf(keep + kept, sizeof keep - kept,
			    "%s%d", kept == 0 ? "" : ";", v);
		} else if (have)
			all = 0;
		v = 0;
		have = 0;
	}
	if (all)
		goto write;
	if (kept != 0)
		evbuffer_add_printf(out, "\033[?%s%c", keep, final);
	return;

write:
	evbuffer_add(out, s, n);
}

/* A piece of pane output: text, or one whole sequence. */
struct forward_piece {
	size_t	 off;
	size_t	 len;
	int	 sequence;
};

struct forward_pieces {
	struct evbuffer		*data;
	struct forward_piece	*list;
	u_int			 n;
	u_int			 size;
};

static void
forward_add(struct forward_pieces *fp, const u_char *s, size_t len,
    int sequence)
{
	struct forward_piece	*last;

	if (!sequence && fp->n != 0) {
		last = &fp->list[fp->n - 1];
		if (!last->sequence) {
			evbuffer_add(fp->data, s, len);
			last->len += len;
			return;
		}
	}
	if (fp->n == fp->size) {
		fp->size = fp->size == 0 ? 64 : fp->size * 2;
		fp->list = xreallocarray(fp->list, fp->size, sizeof *fp->list);
	}
	fp->list[fp->n].off = EVBUFFER_LENGTH(fp->data);
	fp->list[fp->n].len = len;
	fp->list[fp->n].sequence = sequence;
	fp->n++;
	evbuffer_add(fp->data, s, len);
}

/*
 * Split pane output into text and whole sequences; a sequence cut off at the
 * end of the buffer waits in the pane for the next read, and one too long to
 * judge is dropped.
 */
static void
forward_split(struct window_pane *wp, const u_char *buf, size_t len,
    struct forward_pieces *fp)
{
	size_t	 i;
	u_char	 ch;

	for (i = 0; i < len; i++) {
		ch = buf[i];
		switch (wp->fwd_state) {
		case FWD_GROUND:
			if (ch == '\033') {
				wp->fwd_len = 0;
				wp->fwd_buf[wp->fwd_len++] = ch;
				wp->fwd_state = FWD_ESC;
			} else if (ch != '\005')	/* ENQ: answerback */
				forward_add(fp, &ch, 1, 0);
			continue;
		case FWD_ESC:
			if (wp->fwd_len < sizeof wp->fwd_buf)
				wp->fwd_buf[wp->fwd_len++] = ch;
			if (ch == '[')
				wp->fwd_state = FWD_CSI;
			else if (ch == ']' || ch == 'P' || ch == '_' ||
			    ch == '^' || ch == 'X')
				wp->fwd_state = FWD_STRING;
			else if (ch >= ' ' && ch <= '/')
				;			/* intermediate: ESC ( B */
			else
				goto done;
			continue;
		case FWD_CSI:
			if (wp->fwd_len < sizeof wp->fwd_buf)
				wp->fwd_buf[wp->fwd_len++] = ch;
			if (ch >= '@' && ch <= '~')
				goto done;
			continue;
		case FWD_STRING:
			if (wp->fwd_len < sizeof wp->fwd_buf)
				wp->fwd_buf[wp->fwd_len++] = ch;
			if (ch == '\007')
				goto done;
			if (ch == '\033')
				wp->fwd_state = FWD_STRING_ESC;
			continue;
		case FWD_STRING_ESC:
			if (wp->fwd_len < sizeof wp->fwd_buf)
				wp->fwd_buf[wp->fwd_len++] = ch;
			if (ch == '\\')
				goto done;
			wp->fwd_state = FWD_STRING;
			continue;
		}
	done:
		wp->fwd_state = FWD_GROUND;
		if (wp->fwd_len != sizeof wp->fwd_buf)
			forward_add(fp, wp->fwd_buf, wp->fwd_len, 1);
	}
}

/* Could this client show this pane by forwarding its output? */
int
forward_eligible(struct client *c, struct window_pane *wp)
{
	struct window		*w;
	struct grid_cell	 gc;
	u_int			 dim = 0;

	if (c->flags & (CLIENT_CONTROL|CLIENT_SUSPENDED|CLIENT_EXIT|CLIENT_DEAD))
		return (0);
	if (c->session == NULL || (~c->tty.flags & TTY_STARTED))
		return (0);
	if (c->tty.flags & (TTY_BLOCK|TTY_FREEZE))
		return (0);
	if (options_get_number(global_options, "clear-on-attach"))
		return (0);
	if (!options_get_number(global_options, "forward-output"))
		return (0);
	w = c->session->curw->window;
	if (wp->window != w || w->active != wp || w->menu != NULL)
		return (0);
	if (window_count_panes(w, 1) != 1)
		return (0);
	if (c->prompt != NULL || c->message_string != NULL)
		return (0);
	if (status_line_size(c) != 0 || !TAILQ_EMPTY(&wp->modes))
		return (0);
	if (wp->xoff != 0 || wp->yoff != 0 || wp->sx != c->tty.sx ||
	    wp->sy != c->tty.sy)
		return (0);
	/* Output that is not UTF-8 would need changing for the terminal. */
	if (~c->flags & CLIENT_UTF8)
		return (0);
	/* tmux draws the pane's style and palette in; the program cannot. */
	tty_default_colours(&gc, wp, &dim);
	if (gc.fg != 8 || gc.bg != 8 || dim != 0)
		return (0);
	if (wp->palette.default_palette != NULL)
		return (0);
	return (1);
}

/*
 * The pane is in a state the terminal can take over from: between sequences,
 * default attributes and charset, autowrap, no scroll region, not waiting to
 * wrap.
 */
static int
forward_can_start(struct window_pane *wp)
{
	struct screen	*s = wp->screen;

	if (wp->fwd_state != FWD_GROUND || !input_is_ground(wp->ictx))
		return (0);
	if (!input_cell_is_default(wp->ictx))
		return (0);
	if ((~s->mode & MODE_WRAP) || (s->mode & (MODE_ORIGIN|MODE_INSERT)))
		return (0);
	if (s->rupper != 0 || s->rlower != screen_size_y(s) - 1)
		return (0);
	if (s->cx >= screen_size_x(s))
		return (0);
	return (1);
}

/*
 * A pane has output: write it to each client forwarding the pane, as that
 * client's terminal can show it, starting any client that now qualifies.
 */
void
forward_pane_output(struct window_pane *wp, const u_char *buf, size_t len)
{
	struct client		*c;
	struct forward_pieces	 fp;
	struct forward_piece	*p;
	struct evbuffer		*out;
	const u_char		*data;
	u_int			 i;
	int			 start, any = 0;

	start = forward_can_start(wp);
	TAILQ_FOREACH(c, &clients, entry) {
		if (c->forward_pane == wp->id) {
			if (forward_eligible(c, wp)) {
				any = 1;
				continue;
			}
			forward_stop(c);
		} else if (start && forward_eligible(c, wp) &&
		    (c->flags & CLIENT_ALLREDRAWFLAGS) == 0) {
			log_debug("%s: %s forwards %%%u", __func__, c->name,
			    wp->id);
			c->forward_pane = wp->id;
			any = 1;
		}
	}

	memset(&fp, 0, sizeof fp);
	if ((fp.data = evbuffer_new()) == NULL)
		fatalx("out of memory");
	forward_split(wp, buf, len, &fp);
	if (any && fp.n != 0) {
		data = EVBUFFER_DATA(fp.data);
		if ((out = evbuffer_new()) == NULL)
			fatalx("out of memory");
		TAILQ_FOREACH(c, &clients, entry) {
			if (c->forward_pane != wp->id)
				continue;
			for (i = 0; i < fp.n; i++) {
				p = &fp.list[i];
				if (p->sequence) {
					forward_sequence(&c->tty,
					    data + p->off, p->len, out);
				} else
					evbuffer_add(out, data + p->off, p->len);
			}
			tty_forward(&c->tty, EVBUFFER_DATA(out),
			    EVBUFFER_LENGTH(out));
			evbuffer_drain(out, EVBUFFER_LENGTH(out));
		}
		evbuffer_free(out);
	}
	evbuffer_free(fp.data);
	free(fp.list);
}

/*
 * The pane has parsed what was forwarded: the terminal has everything the pane
 * put in its history, and is on the screen - main or alternate - the pane is.
 */
void
forward_pane_parsed(struct window_pane *wp)
{
	struct client	*c;
	struct grid	*gd = wp->base.grid;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->forward_pane != wp->id)
			continue;
		c->tty.hist_pane = wp->id;
		c->tty.hist_seen = gd->scroll_view;
		c->tty.hist_gen = gd->scroll_generation;
		if (SCREEN_IS_ALTERNATE(&wp->base))
			c->tty.flags |= TTY_ALTSCREEN;
		else
			c->tty.flags &= ~TTY_ALTSCREEN;
	}
}

/* Stop forwarding to a client and draw it from the grid again. */
void
forward_stop(struct client *c)
{
	if (c->forward_pane == UINT_MAX)
		return;
	log_debug("%s: %s stops forwarding %%%u", __func__, c->name,
	    c->forward_pane);
	c->forward_pane = UINT_MAX;
	/* tty_stop_tty stops forwarding first; never write to a stopped tty. */
	if (~c->tty.flags & TTY_STARTED)
		return;
	tty_puts(&c->tty, FORWARD_RESET);
	tty_invalidate(&c->tty);
	server_redraw_client(c);
}

/* Check every forwarding client still qualifies. */
void
forward_check(void)
{
	struct client		*c;
	struct window_pane	*wp;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->forward_pane == UINT_MAX)
			continue;
		wp = window_pane_find_by_id(c->forward_pane);
		if (wp == NULL || !forward_eligible(c, wp))
			forward_stop(c);
	}
}
