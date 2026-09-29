/* $OpenBSD: tty.c,v 1.482 2026/09/22 06:58:06 nicm Exp $ */

/*
 * Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
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
#include <sys/ioctl.h>

#include <netinet/in.h>

#include <curses.h>
#include <errno.h>
#include <fcntl.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "tmux.h"

static int	tty_log_fd = -1;

static void	tty_count_history(struct tty *, const struct tty_ctx *);
static int	tty_rewrap(struct tty *, const struct tty_ctx *, u_int, u_int,
		    u_int);
static void	tty_pay_scroll(struct tty *);
static void	tty_start_timer_callback(int, short, void *);
static void	tty_clipboard_query_callback(int, short, void *);
static void	tty_set_italics(struct tty *);
static int	tty_try_colour(struct tty *, int, const char *);
static void	tty_force_cursor_colour(struct tty *, int);
static void	tty_cursor_pane(struct tty *, const struct tty_ctx *, u_int,
		    u_int);
static void	tty_cursor_pane_unless_wrap(struct tty *,
		    const struct tty_ctx *, u_int, u_int);
static void	tty_colours(struct tty *, const struct grid_cell *);
static void	tty_check_fg(struct tty *, struct colour_palette *,
		    struct grid_cell *);
static void	tty_check_bg(struct tty *, struct colour_palette *,
		    struct grid_cell *);
static void	tty_check_us(struct tty *, struct colour_palette *,
		    struct grid_cell *);
static int	tty_map_theme_colour(struct tty *, int);
static void	tty_colours_fg(struct tty *, const struct grid_cell *);
static void	tty_colours_bg(struct tty *, const struct grid_cell *);
static void	tty_colours_us(struct tty *, const struct grid_cell *);

static void	tty_region_pane(struct tty *, const struct tty_ctx *, u_int,
		    u_int);
static void	tty_region(struct tty *, u_int, u_int);
static void	tty_margin_pane(struct tty *, const struct tty_ctx *);
static void	tty_margin(struct tty *, u_int, u_int);
static int	tty_large_region(struct tty *, const struct tty_ctx *);
static void	tty_redraw_region(struct tty *, const struct tty_ctx *);
static void	tty_emulate_repeat(struct tty *, enum tty_code_code,
		    enum tty_code_code, u_int);
static void	tty_draw_pane(struct tty *, const struct tty_ctx *, u_int);

#ifdef ENABLE_SIXEL
static void	tty_write_one(void (*)(struct tty *, const struct tty_ctx *),
		    struct client *, struct tty_ctx *);
#endif

#define tty_use_margin(tty) \
	(tty->term->flags & TERM_DECSLRM)
#define tty_full_width(tty, ctx) \
	((ctx)->xoff == 0 && (ctx)->sx >= (tty)->sx)

#define TTY_BLOCK_INTERVAL (100000 /* 100 milliseconds */)
#define TTY_BLOCK_START(tty) (1 + ((tty)->sx * (tty)->sy) * 8)
#define TTY_BLOCK_STOP(tty) (1 + ((tty)->sx * (tty)->sy) / 8)

#define TTY_QUERY_TIMEOUT 5
#define TTY_REQUEST_LIMIT 30

static struct tty_style_ctx tty_default_style_ctx = {
	&grid_default_cell, NULL, 0, NULL
};

void
tty_create_log(void)
{
	char	name[64];

	xsnprintf(name, sizeof name, "tmux-out-%ld.log", (long)getpid());

	tty_log_fd = open(name, O_WRONLY|O_CREAT|O_TRUNC, 0644);
	if (tty_log_fd != -1 && fcntl(tty_log_fd, F_SETFD, FD_CLOEXEC) == -1)
		fatal("fcntl failed");
}

int
tty_init(struct tty *tty, struct client *c)
{
	if (!isatty(c->fd))
		return (-1);

	memset(tty, 0, sizeof *tty);
	tty->client = c;

	tty->cstyle = SCREEN_CURSOR_DEFAULT;
	tty->ccolour = -1;
	tty->fg = tty->bg = -1;
	tty->mouse_last_pane = -1;
	tty->hist_pane = UINT_MAX;
	tty->hist_shown = UINT_MAX;

	if (tcgetattr(c->fd, &tty->tio) != 0)
		return (-1);
	return (0);
}

void
tty_resize(struct tty *tty)
{
	struct client	*c = tty->client;
	struct winsize	 ws;
	u_int		 sx, sy, xpixel, ypixel;

	if (ioctl(c->fd, TIOCGWINSZ, &ws) != -1) {
		sx = ws.ws_col;
		if (sx == 0) {
			sx = 80;
			xpixel = 0;
		} else
			xpixel = ws.ws_xpixel / sx;
		sy = ws.ws_row;
		if (sy == 0) {
			sy = 24;
			ypixel = 0;
		} else
			ypixel = ws.ws_ypixel / sy;

		if ((xpixel == 0 || ypixel == 0) &&
		    tty->out != NULL &&
		    !(tty->flags & TTY_WINSIZEQUERY) &&
		    (tty->term->flags & TERM_VT100LIKE)) {
			tty_puts(tty, "\033[18t\033[14t");
			tty->flags |= TTY_WINSIZEQUERY;
		}
	} else {
		sx = 80;
		sy = 24;
		xpixel = 0;
		ypixel = 0;
	}
	log_debug("%s: %s now %ux%u (%ux%u)", __func__, c->name, sx, sy,
	    xpixel, ypixel);
	tty_set_size(tty, sx, sy, xpixel, ypixel);
	tty_invalidate(tty);
}

void
tty_set_size(struct tty *tty, u_int sx, u_int sy, u_int xpixel, u_int ypixel)
{
	tty->sx = sx;
	tty->sy = sy;
	tty->xpixel = xpixel;
	tty->ypixel = ypixel;
}

static void
tty_read_callback(__unused int fd, __unused short events, void *data)
{
	struct tty	*tty = data;
	struct client	*c = tty->client;
	const char	*name = c->name;
	size_t		 size = EVBUFFER_LENGTH(tty->in);
	int		 nread;

	nread = evbuffer_read(tty->in, c->fd, -1);
	if (nread == 0 || nread == -1) {
		if (nread == 0)
			log_debug("%s: read closed", name);
		else
			log_debug("%s: read error: %s", name, strerror(errno));
		event_del(&tty->event_in);
		server_client_lost(tty->client);
		return;
	}
	log_debug("%s: read %d bytes (already %zu)", name, nread, size);

	while (tty_keys_next(tty))
		;
}

static void
tty_timer_callback(__unused int fd, __unused short events, void *data)
{
	struct tty	*tty = data;
	struct client	*c = tty->client;
	struct timeval	 tv = { .tv_usec = TTY_BLOCK_INTERVAL };

	log_debug("%s: %zu discarded", c->name, tty->discarded);

	c->flags |= CLIENT_ALLREDRAWFLAGS;
	c->discarded += tty->discarded;

	if (tty->discarded < TTY_BLOCK_STOP(tty)) {
		tty->flags &= ~TTY_BLOCK;
		tty_invalidate(tty);
		return;
	}
	tty->discarded = 0;
	evtimer_add(&tty->timer, &tv);
}

static int
tty_block_maybe(struct tty *tty)
{
	struct client	*c = tty->client;
	size_t		 size = EVBUFFER_LENGTH(tty->out);
	struct timeval	 tv = { .tv_usec = TTY_BLOCK_INTERVAL };

	if (size == 0)
		tty->flags &= ~TTY_NOBLOCK;
	else if (tty->flags & TTY_NOBLOCK)
		return (0);

	if (size < TTY_BLOCK_START(tty))
		return (0);

	if (tty->flags & TTY_BLOCK)
		return (1);
	tty->flags |= TTY_BLOCK;

	log_debug("%s: can't keep up, %zu discarded", c->name, size);

	evbuffer_drain(tty->out, size);
	c->discarded += size;

	tty->discarded = 0;
	evtimer_add(&tty->timer, &tv);
	return (1);
}

static void
tty_write_callback(__unused int fd, __unused short events, void *data)
{
	struct tty	*tty = data;
	struct client	*c = tty->client;
	size_t		 size = EVBUFFER_LENGTH(tty->out);
	int		 nwrite;

	nwrite = evbuffer_write(tty->out, c->fd);
	if (nwrite == -1)
		return;
	log_debug("%s: wrote %d bytes (of %zu)", c->name, nwrite, size);

	if (c->redraw > 0) {
		if ((size_t)nwrite >= c->redraw)
			c->redraw = 0;
		else
			c->redraw -= nwrite;
		log_debug("%s: waiting for redraw, %zu bytes left", c->name,
		    c->redraw);
	} else if (tty_block_maybe(tty))
		return;

	if (EVBUFFER_LENGTH(tty->out) != 0)
		event_add(&tty->event_out, NULL);
}

int
tty_open(struct tty *tty, char **cause)
{
	struct client	*c = tty->client;

	tty->term = tty_term_create(tty, c->term_name, c->term_caps,
	    c->term_ncaps, cause);
	if (tty->term == NULL) {
		tty_close(tty);
		return (-1);
	}
	tty->flags |= TTY_OPENED;

	tty->flags &= ~(TTY_NOCURSOR|TTY_FREEZE|TTY_BLOCK|TTY_TIMER);

	event_set(&tty->event_in, c->fd, EV_PERSIST|EV_READ,
	    tty_read_callback, tty);
	tty->in = evbuffer_new();
	if (tty->in == NULL)
		fatal("out of memory");

	event_set(&tty->event_out, c->fd, EV_WRITE, tty_write_callback, tty);
	tty->out = evbuffer_new();
	if (tty->out == NULL)
		fatal("out of memory");

	evtimer_set(&tty->clipboard_timer, tty_clipboard_query_callback, tty);
	evtimer_set(&tty->start_timer, tty_start_timer_callback, tty);
	evtimer_set(&tty->timer, tty_timer_callback, tty);

	tty_start_tty(tty);
	tty_keys_build(tty);

	return (0);
}

static void
tty_start_timer_callback(__unused int fd, __unused short events, void *data)
{
	struct tty	*tty = data;
	struct client	*c = tty->client;

	log_debug("%s: start timer fired", c->name);

	if ((tty->flags & (TTY_HAVEDA|TTY_HAVEDA2|TTY_HAVEXDA)) == 0)
		tty_update_features(tty);
	tty->flags |= TTY_ALL_REQUEST_FLAGS;

	tty->flags &= ~(TTY_WAITBG|TTY_WAITFG);
}

static void
tty_start_start_timer(struct tty *tty)
{
	struct client	*c = tty->client;
	struct timeval	 tv = { .tv_sec = TTY_QUERY_TIMEOUT };

	log_debug("%s: start timer started", c->name);
	evtimer_del(&tty->start_timer);
	evtimer_add(&tty->start_timer, &tv);
}

void
tty_start_tty(struct tty *tty)
{
	struct client	*c = tty->client;
	struct termios	 tio;
	u_int		 i;

	setblocking(c->fd, 0);
	event_add(&tty->event_in, NULL);

	memcpy(&tio, &tty->tio, sizeof tio);
	tio.c_iflag &= ~(IXON|IXOFF|ICRNL|INLCR|IGNCR|IMAXBEL|ISTRIP);
	tio.c_iflag |= IGNBRK;
	tio.c_oflag &= ~(OPOST|ONLCR|OCRNL|ONLRET);
	tio.c_lflag &= ~(IEXTEN|ICANON|ECHO|ECHOE|ECHONL|ECHOCTL|ECHOPRT|
	    ECHOKE|ISIG);
	tio.c_cc[VMIN] = 1;
	tio.c_cc[VTIME] = 0;
	if (tcsetattr(c->fd, TCSANOW, &tio) == 0)
		tcflush(c->fd, TCOFLUSH);

	if (clear_on_attach) {
		tty_putcode(tty, TTYC_SMCUP);
		tty_putcode(tty, TTYC_CLEAR);
	} else {
		tty_putcode_ii(tty, TTYC_CSR, 0, tty->sy - 1);
		tty_putcode_ii(tty, TTYC_CUP, 0, tty->sy - 1);
		if (tty_term_has(tty->term, TTYC_INDN))
			tty_putcode_i(tty, TTYC_INDN, tty->sy + 1);
		else if (tty_term_has(tty->term, TTYC_IND)) {
			for (i = 0; i < tty->sy + 1; i++)
				tty_putcode(tty, TTYC_IND);
		} else
			tty_putcode(tty, TTYC_CLEAR);
	}
	tty_putcode(tty, TTYC_SMKX);

	if (tty_acs_needed(tty)) {
		log_debug("%s: using capabilities for ACS", c->name);
		tty_putcode(tty, TTYC_ENACS);
	} else
		log_debug("%s: using UTF-8 for ACS", c->name);

	tty_putcode(tty, TTYC_CNORM);
	if (tty_term_has(tty->term, TTYC_KMOUS)) {
		tty_puts(tty, "\033[?1000l\033[?1002l\033[?1003l");
		tty_puts(tty, "\033[?1006l\033[?1005l");
	}
	if (tty_term_has(tty->term, TTYC_ENBP))
		tty_putcode(tty, TTYC_ENBP);

	if (tty->term->flags & TERM_VT100LIKE) {
		/* Subscribe to theme changes and request theme now. */
		tty_puts(tty, "\033[?2031h\033[?996n");
	}

	tty_start_start_timer(tty);

	tty->flags |= TTY_STARTED;
	tty->flags &= ~TTY_ALTSCREEN;
	tty_invalidate(tty);

	if (tty->ccolour != -1)
		tty_force_cursor_colour(tty, -1);

	tty->mouse_drag_flag = 0;
	tty->mouse_drag_update = NULL;
	tty->mouse_drag_release = NULL;
}

void
tty_send_requests(struct tty *tty)
{
	if (~tty->flags & TTY_STARTED)
		return;

	if (tty->term->flags & TERM_VT100LIKE) {
		if (~tty->flags & TTY_HAVEDA)
			tty_puts(tty, "\033[c");
		if (~tty->flags & TTY_HAVEDA2)
			tty_puts(tty, "\033[>c");
		if (~tty->flags & TTY_HAVEXDA)
			tty_puts(tty, "\033[>q");
		if (~tty->flags & TTY_HAVESYNC)
			tty_puts(tty, "\033[?2026$p");
		tty_puts(tty, "\033]10;?\033\\\033]11;?\033\\");
		tty->flags |= (TTY_WAITBG|TTY_WAITFG);
	} else
		tty->flags |= TTY_ALL_REQUEST_FLAGS;
	tty->last_requests = time(NULL);
}

void
tty_repeat_requests(struct tty *tty, int force)
{
	struct client	*c = tty->client;
	time_t		 t = time(NULL);
	u_int		 n = t - tty->last_requests;

	if (~tty->flags & TTY_STARTED)
		return;

	if (!force && n <= TTY_REQUEST_LIMIT) {
		log_debug("%s: not repeating requests (%u seconds)", c->name,
		    n);
		return;
	}
	log_debug("%s: %srepeating requests (%u seconds)", c->name,
	    force ? "(force) " : "" , n);
	tty->last_requests = t;

	if (tty->term->flags & TERM_VT100LIKE) {
		tty_puts(tty, "\033]10;?\033\\\033]11;?\033\\");
		tty->flags |= (TTY_WAITBG|TTY_WAITFG);
	}
	tty_start_start_timer(tty);
}

void
tty_stop_tty(struct tty *tty)
{
	struct client	*c = tty->client;
	struct winsize	 ws;

	if (!(tty->flags & TTY_STARTED))
		return;
	tty->flags &= ~TTY_STARTED;

	evtimer_del(&tty->start_timer);
	evtimer_del(&tty->clipboard_timer);

	event_del(&tty->timer);
	tty->flags &= ~TTY_BLOCK;

	event_del(&tty->event_in);
	event_del(&tty->event_out);

	/*
	 * Be flexible about error handling and try not kill the server just
	 * because the fd is invalid. Things like ssh -t can easily leave us
	 * with a dead tty.
	 */
	if (ioctl(c->fd, TIOCGWINSZ, &ws) == -1)
		return;
	if (tcsetattr(c->fd, TCSANOW, &tty->tio) == -1)
		return;

	if (tty->flags & TTY_OWESCROLL) {
		tty->flags &= ~TTY_OWESCROLL;
		tty_raw(tty, "\r\n");
	}
	tty_raw(tty, tty_term_string_ii(tty->term, TTYC_CSR, 0, ws.ws_row - 1));
	if (tty_acs_needed(tty))
		tty_raw(tty, tty_term_string(tty->term, TTYC_RMACS));
	tty_raw(tty, tty_term_string(tty->term, TTYC_SGR0));
	tty_raw(tty, tty_term_string(tty->term, TTYC_RMKX));
	if (clear_on_attach)
		tty_raw(tty, tty_term_string(tty->term, TTYC_CLEAR));
	if (tty->cstyle != SCREEN_CURSOR_DEFAULT) {
		if (tty_term_has(tty->term, TTYC_SE))
			tty_raw(tty, tty_term_string(tty->term, TTYC_SE));
		else if (tty_term_has(tty->term, TTYC_SS))
			tty_raw(tty, tty_term_string_i(tty->term, TTYC_SS, 0));
	}
	if (tty->ccolour != -1)
		tty_raw(tty, tty_term_string(tty->term, TTYC_CR));

	tty_raw(tty, tty_term_string(tty->term, TTYC_CNORM));
	if (tty_term_has(tty->term, TTYC_KMOUS)) {
		tty_raw(tty, "\033[?1000l\033[?1002l\033[?1003l");
		tty_raw(tty, "\033[?1006l\033[?1005l");
	}
	if (tty_term_has(tty->term, TTYC_DSBP))
		tty_raw(tty, tty_term_string(tty->term, TTYC_DSBP));

	tty_raw(tty, tty_term_string(tty->term, TTYC_DSESC));
	tty_raw(tty, tty_term_string(tty->term, TTYC_DSFCS));
	tty_raw(tty, tty_term_string(tty->term, TTYC_DSEKS));

	if (tty_use_margin(tty))
		tty_raw(tty, tty_term_string(tty->term, TTYC_DSMG));

	/*
	 * Leave the alternate screen if a full-window pane put us there (see
	 * server_client_check_redraw), so the terminal is not left in it.
	 */
	if (tty->flags & TTY_ALTSCREEN) {
		tty_raw(tty, tty_term_string(tty->term, TTYC_RMCUP));
		tty->flags &= ~TTY_ALTSCREEN;
	}
	if (clear_on_attach)
		tty_raw(tty, tty_term_string(tty->term, TTYC_RMCUP));
	else
		tty_raw(tty, tty_term_string(tty->term, TTYC_CLEAR));

	if (tty->term->flags & TERM_VT100LIKE)
		tty_raw(tty, "\033[?2031l");

	setblocking(c->fd, 1);
}

void
tty_close(struct tty *tty)
{
	if (event_initialized(&tty->key_timer))
		evtimer_del(&tty->key_timer);
	tty_stop_tty(tty);

	if (tty->flags & TTY_OPENED) {
		evbuffer_free(tty->in);
		event_del(&tty->event_in);
		evbuffer_free(tty->out);
		event_del(&tty->event_out);

		tty_term_free(tty->term);
		tty_keys_free(tty);

		tty->flags &= ~TTY_OPENED;
	}
}

void
tty_free(struct tty *tty)
{
	tty_close(tty);
}

void
tty_update_features(struct tty *tty)
{
	struct client	*c = tty->client;

	if (tty_apply_features(tty->term))
		tty_term_apply_overrides(tty->term);

	if (tty_use_margin(tty))
		tty_putcode(tty, TTYC_ENMG);
	if (options_get_number(global_options, "extended-keys"))
		tty_puts(tty, tty_term_string(tty->term, TTYC_ENEKS));
	if (options_get_number(global_options, "focus-events"))
		tty_puts(tty, tty_term_string(tty->term, TTYC_ENFCS));
	tty_puts(tty, tty_term_string(tty->term, TTYC_ENESC));

	/*
	 * Features might have changed since the first draw during attach. For
	 * example, this happens when DA responses are received.
	 */
	server_redraw_client(c);

	tty_invalidate(tty);
}

void
tty_raw(struct tty *tty, const char *s)
{
	struct client	*c = tty->client;
	ssize_t		 n, slen;
	u_int		 i;

	slen = strlen(s);
	for (i = 0; i < 5; i++) {
		n = write(c->fd, s, slen);
		if (n >= 0) {
			s += n;
			slen -= n;
			if (slen == 0)
				break;
		} else if (n == -1 && errno != EAGAIN)
			break;
		usleep(100);
	}
}

void
tty_putcode(struct tty *tty, enum tty_code_code code)
{
	tty_puts(tty, tty_term_string(tty->term, code));
}

void
tty_putcode_i(struct tty *tty, enum tty_code_code code, int a)
{
	if (a < 0)
		return;
	tty_puts(tty, tty_term_string_i(tty->term, code, a));
}

void
tty_putcode_ii(struct tty *tty, enum tty_code_code code, int a, int b)
{
	if (a < 0 || b < 0)
		return;
	tty_puts(tty, tty_term_string_ii(tty->term, code, a, b));
}

void
tty_putcode_iii(struct tty *tty, enum tty_code_code code, int a, int b, int c)
{
	if (a < 0 || b < 0 || c < 0)
		return;
	tty_puts(tty, tty_term_string_iii(tty->term, code, a, b, c));
}

void
tty_putcode_s(struct tty *tty, enum tty_code_code code, const char *a)
{
	if (a != NULL)
		tty_puts(tty, tty_term_string_s(tty->term, code, a));
}

void
tty_putcode_ss(struct tty *tty, enum tty_code_code code, const char *a,
    const char *b)
{
	if (a != NULL && b != NULL)
		tty_puts(tty, tty_term_string_ss(tty->term, code, a, b));
}

static void
tty_add(struct tty *tty, const char *buf, size_t len)
{
	struct client	*c = tty->client;

	if (tty->flags & TTY_BLOCK) {
		tty->discarded += len;
		return;
	}

	evbuffer_add(tty->out, buf, len);
	log_debug("%s: %.*s", c->name, (int)len, buf);
	c->written += len;

	if (tty_log_fd != -1)
		write(tty_log_fd, buf, len);
	if ((tty->flags & TTY_STARTED) &&
	    !event_pending(&tty->event_out, EV_WRITE, NULL))
		event_add(&tty->event_out, NULL);
}

void
tty_puts(struct tty *tty, const char *s)
{
	if (*s != '\0')
		tty_add(tty, s, strlen(s));
}

/*
 * Write a pane's output as the program wrote it (forward.c). Where the cursor
 * is and which region and margins are set is then up to the terminal.
 */
void
tty_forward(struct tty *tty, const u_char *buf, size_t len)
{
	tty_add(tty, (const char *)buf, len);
	/* The program's attributes are the terminal's now; tmux resets them
	 * with tty_invalidate when it draws again (forward_stop). */
	memcpy(&tty->cell, &grid_default_cell, sizeof tty->cell);
	tty->flags &= ~(TTY_OWESCROLL|TTY_WRAPNEXT|TTY_WRAPPED0);
	tty->cx = tty->cy = UINT_MAX;
	tty->rupper = tty->rleft = UINT_MAX;
	tty->rlower = tty->rright = UINT_MAX;
}

void
tty_putc(struct tty *tty, u_char ch)
{
	const char	*acs;

	if ((tty->term->flags & TERM_NOAM) &&
	    ch >= 0x20 && ch != 0x7f &&
	    tty->cy == tty->sy - 1 &&
	    tty->cx + 1 >= tty->sx)
		return;

	if (tty->cell.attr & GRID_ATTR_CHARSET) {
		acs = tty_acs_get(tty, ch);
		if (acs != NULL)
			tty_add(tty, acs, strlen(acs));
		else
			tty_add(tty, &ch, 1);
	} else
		tty_add(tty, &ch, 1);

	tty->flags &= ~TTY_WRAPPED0;
	if (ch >= 0x20 && ch != 0x7f) {
		if (tty->cx >= tty->sx) {
			tty->flags &= ~(TTY_OWESCROLL|TTY_WRAPNEXT);
			tty->cx = 1;
			if (tty->cy != tty->rlower)
				tty->cy++;

			/*
			 * On !am terminals, force the cursor position to where
			 * we think it should be after a line wrap - this means
			 * it works on sensible terminals as well.
			 */
			if (tty->term->flags & TERM_NOAM)
				tty_putcode_ii(tty, TTYC_CUP, tty->cy, tty->cx);
		} else
			tty->cx++;
	}
}

void
tty_putn(struct tty *tty, const void *buf, size_t len, u_int width)
{
	if ((tty->term->flags & TERM_NOAM) &&
	    tty->cy == tty->sy - 1 &&
	    tty->cx + len >= tty->sx)
		len = tty->sx - tty->cx - 1;

	tty_add(tty, buf, len);
	tty->flags &= ~TTY_WRAPPED0;
	if (tty->cx + width > tty->sx) {
		tty->flags &= ~(TTY_OWESCROLL|TTY_WRAPNEXT);
		tty->cx = (tty->cx + width) - tty->sx;
		if (tty->cx > tty->sx)
			tty->cx = tty->cy = UINT_MAX;
		else if (tty->cy != tty->rlower)
			tty->cy++;
	} else
		tty->cx += width;
}

static void
tty_set_italics(struct tty *tty)
{
	const char	*s;

	if (tty_term_has(tty->term, TTYC_SITM)) {
		s = options_get_string(global_options, "default-terminal");
		if (strcmp(s, "screen") != 0 && strncmp(s, "screen-", 7) != 0) {
			tty_putcode(tty, TTYC_SITM);
			return;
		}
	}
	tty_putcode(tty, TTYC_SMSO);
}

void
tty_set_title(struct tty *tty, const char *title)
{
	if (!tty_term_has(tty->term, TTYC_TSL) ||
	    !tty_term_has(tty->term, TTYC_FSL))
		return;

	tty_putcode(tty, TTYC_TSL);
	tty_puts(tty, title);
	tty_putcode(tty, TTYC_FSL);
}

void
tty_set_path(struct tty *tty, const char *title)
{
	if (!tty_term_has(tty->term, TTYC_SWD) ||
	    !tty_term_has(tty->term, TTYC_FSL))
		return;

	tty_putcode(tty, TTYC_SWD);
	tty_puts(tty, title);
	tty_putcode(tty, TTYC_FSL);
}

static void
tty_force_cursor_colour(struct tty *tty, int c)
{
	u_char	r, g, b;
	char	s[13];

	if (c != -1) {
		c = tty_map_theme_colour(tty, c);
		c = colour_force_rgb(c);
	}
	if (c == tty->ccolour)
		return;
	if (c == -1)
		tty_putcode(tty, TTYC_CR);
	else {
		colour_split_rgb(c, &r, &g, &b);
		xsnprintf(s, sizeof s, "rgb:%02hhx/%02hhx/%02hhx", r, g, b);
		tty_putcode_s(tty, TTYC_CS, s);
	}
	tty->ccolour = c;
}

static int
tty_update_cursor(struct tty *tty, int mode, struct screen *s)
{
	enum screen_cursor_style	cstyle;
	int				ccolour, changed, cmode = mode;

	/* Set cursor colour if changed. */
	if (s != NULL) {
		ccolour = s->ccolour;
		if (s->ccolour == -1)
			ccolour = s->default_ccolour;
		tty_force_cursor_colour(tty, ccolour);
	}

	/* If cursor is off, set as invisible. */
	if (~cmode & MODE_CURSOR) {
		if (tty->mode & MODE_CURSOR)
			tty_putcode(tty, TTYC_CIVIS);
		return (cmode);
	}

	/* Check if blinking or very visible flag changed or style changed. */
	if (s == NULL)
		cstyle = tty->cstyle;
	else {
		cstyle = s->cstyle;
		if (cstyle == SCREEN_CURSOR_DEFAULT) {
			if (~cmode & MODE_CURSOR_BLINKING_SET) {
				if (s->default_mode & MODE_CURSOR_BLINKING)
					cmode |= MODE_CURSOR_BLINKING;
				else
					cmode &= ~MODE_CURSOR_BLINKING;
			}
			cstyle = s->default_cstyle;
		}
	}

	/* If nothing changed, do nothing. */
	changed = cmode ^ tty->mode;
	if ((changed & CURSOR_MODES) == 0 && cstyle == tty->cstyle)
		return (cmode);

	/*
	 * Set cursor style. If an explicit style has been set with DECSCUSR,
	 * set it if supported, otherwise send cvvis for blinking styles.
	 *
	 * If no style, has been set (SCREEN_CURSOR_DEFAULT), then send cvvis
	 * if either the blinking or very visible flags are set.
	 */
	tty_putcode(tty, TTYC_CNORM);
	switch (cstyle) {
	case SCREEN_CURSOR_DEFAULT:
		if (tty->cstyle != SCREEN_CURSOR_DEFAULT) {
			if (tty_term_has(tty->term, TTYC_SE))
				tty_putcode(tty, TTYC_SE);
			else
				tty_putcode_i(tty, TTYC_SS, 0);
		}
		if (cmode & (MODE_CURSOR_BLINKING|MODE_CURSOR_VERY_VISIBLE))
			tty_putcode(tty, TTYC_CVVIS);
		break;
	case SCREEN_CURSOR_BLOCK:
		if (tty_term_has(tty->term, TTYC_SS)) {
			if (cmode & MODE_CURSOR_BLINKING)
				tty_putcode_i(tty, TTYC_SS, 1);
			else
				tty_putcode_i(tty, TTYC_SS, 2);
		} else if (cmode & MODE_CURSOR_BLINKING)
			tty_putcode(tty, TTYC_CVVIS);
		break;
	case SCREEN_CURSOR_UNDERLINE:
		if (tty_term_has(tty->term, TTYC_SS)) {
			if (cmode & MODE_CURSOR_BLINKING)
				tty_putcode_i(tty, TTYC_SS, 3);
			else
				tty_putcode_i(tty, TTYC_SS, 4);
		} else if (cmode & MODE_CURSOR_BLINKING)
			tty_putcode(tty, TTYC_CVVIS);
		break;
	case SCREEN_CURSOR_BAR:
		if (tty_term_has(tty->term, TTYC_SS)) {
			if (cmode & MODE_CURSOR_BLINKING)
				tty_putcode_i(tty, TTYC_SS, 5);
			else
				tty_putcode_i(tty, TTYC_SS, 6);
		} else if (cmode & MODE_CURSOR_BLINKING)
			tty_putcode(tty, TTYC_CVVIS);
		break;
	}
	tty->cstyle = cstyle;
	return (cmode);
 }

void
tty_update_mode(struct tty *tty, int mode, struct screen *s)
{
	struct tty_term	*term = tty->term;
	struct client	*c = tty->client;
	int		 changed;

	if (tty->flags & TTY_NOCURSOR)
		mode &= ~MODE_CURSOR;

	if (tty_update_cursor(tty, mode, s) & MODE_CURSOR_BLINKING)
		mode |= MODE_CURSOR_BLINKING;
	else
		mode &= ~MODE_CURSOR_BLINKING;

	changed = mode ^ tty->mode;
	if (log_get_level() != 0 && changed != 0) {
		log_debug("%s: current mode %s", c->name,
		    screen_mode_to_string(tty->mode));
		log_debug("%s: setting mode %s", c->name,
		    screen_mode_to_string(mode));
	}

	if ((changed & ALL_MOUSE_MODES) && tty_term_has(term, TTYC_KMOUS)) {
		/*
		 * If the mouse modes have changed, clear then all and apply
		 * again. There are differences in how terminals track the
		 * various bits.
		 */
		tty_puts(tty, "\033[?1006l\033[?1000l\033[?1002l\033[?1003l");
		if (mode & ALL_MOUSE_MODES)
			tty_puts(tty, "\033[?1006h");
		if (mode & MODE_MOUSE_ALL)
			tty_puts(tty, "\033[?1000h\033[?1002h\033[?1003h");
		else if (mode & MODE_MOUSE_BUTTON)
			tty_puts(tty, "\033[?1000h\033[?1002h");
		else if (mode & MODE_MOUSE_STANDARD)
			tty_puts(tty, "\033[?1000h");
	}
	tty->mode = mode;
}

static void
tty_emulate_repeat(struct tty *tty, enum tty_code_code code,
    enum tty_code_code code1, u_int n)
{
	if (tty_term_has(tty->term, code))
		tty_putcode_i(tty, code, n);
	else {
		while (n-- > 0)
			tty_putcode(tty, code1);
	}
}

void
tty_repeat_space(struct tty *tty, u_int n)
{
	static char s[500];

	if (*s != ' ')
		memset(s, ' ', sizeof s);

	while (n > sizeof s) {
		tty_putn(tty, s, sizeof s, sizeof s);
		n -= sizeof s;
	}
	if (n != 0)
		tty_putn(tty, s, n, n);
}

/* Is this window bigger than the terminal? */
int
tty_window_bigger(struct tty *tty)
{
	struct client	*c = tty->client;
	struct window	*w = c->session->curw->window;

	return (tty->sx < w->sx || tty->sy - status_line_size(c) < w->sy);
}

/* What offset should this window be drawn at? */
int
tty_window_offset(struct tty *tty, u_int *ox, u_int *oy, u_int *sx, u_int *sy)
{
	*ox = tty->oox;
	*oy = tty->ooy;
	*sx = tty->osx;
	*sy = tty->osy;

	return (tty->oflag);
}

/* What offset should this window be drawn at? */
static int
tty_window_offset1(struct tty *tty, u_int *ox, u_int *oy, u_int *sx, u_int *sy)
{
	struct client		*c = tty->client;
	struct window		*w = c->session->curw->window;
	struct window_pane	*wp = w->active;
	u_int			 cx, cy, lines;

	lines = status_line_size(c);

	if (tty->sx >= w->sx && tty->sy - lines >= w->sy) {
		*ox = 0;
		*oy = 0;
		*sx = w->sx;
		*sy = w->sy;

		c->pan_window = NULL;
		return (0);
	}

	*sx = tty->sx;
	*sy = tty->sy - lines;

	if (c->pan_window == w) {
		if (*sx >= w->sx)
			c->pan_ox = 0;
		else if (c->pan_ox + *sx > w->sx)
			c->pan_ox = w->sx - *sx;
		*ox = c->pan_ox;
		if (*sy >= w->sy)
			c->pan_oy = 0;
		else if (c->pan_oy + *sy > w->sy)
			c->pan_oy = w->sy - *sy;
		*oy = c->pan_oy;
		return (1);
	}

	if (~wp->screen->mode & MODE_CURSOR) {
		*ox = 0;
		*oy = 0;
	} else {
		cx = wp->xoff + wp->screen->cx;
		cy = wp->yoff + wp->screen->cy;

		if (cx < *sx)
			*ox = 0;
		else if (cx > w->sx - *sx)
			*ox = w->sx - *sx;
		else
			*ox = cx - *sx / 2;

		if (cy < *sy)
			*oy = 0;
		else if (cy > w->sy - *sy)
			*oy = w->sy - *sy;
		else
			*oy = cy - *sy + 1;
	}

	c->pan_window = NULL;
	return (1);
}

/* Update stored offsets for a window and redraw if necessary. */
void
tty_update_window_offset(struct window *w)
{
	struct client	*c;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session != NULL &&
		    c->session->curw != NULL &&
		    c->session->curw->window == w)
			tty_update_client_offset(c);
	}
}

/* Update stored offsets for a client and redraw if necessary. */
void
tty_update_client_offset(struct client *c)
{
	u_int	ox, oy, sx, sy;

	if (~c->flags & CLIENT_TERMINAL)
		return;

	c->tty.oflag = tty_window_offset1(&c->tty, &ox, &oy, &sx, &sy);
	if (ox == c->tty.oox &&
	    oy == c->tty.ooy &&
	    sx == c->tty.osx &&
	    sy == c->tty.osy)
		return;

	log_debug ("%s: %s offset has changed (%u,%u %ux%u -> %u,%u %ux%u)",
	    __func__, c->name, c->tty.oox, c->tty.ooy, c->tty.osx, c->tty.osy,
	    ox, oy, sx, sy);

	c->tty.oox = ox;
	c->tty.ooy = oy;
	c->tty.osx = sx;
	c->tty.osy = sy;

	c->flags |= (CLIENT_REDRAWWINDOW|CLIENT_REDRAWSTATUS);
}

/*
 * Is the region large enough to be worth redrawing once later rather than
 * probably several times now? Currently yes if it is more than 50% of the
 * pane.
 */
static int
tty_large_region(__unused struct tty *tty, const struct tty_ctx *ctx)
{
	return (ctx->orlower - ctx->orupper >= ctx->sy / 2);
}

/*
 * Return if BCE is needed but the terminal doesn't have it - it'll need to be
 * emulated.
 */
int
tty_fake_bce(const struct tty *tty, const struct grid_cell *gc, u_int bg)
{
	if (tty_term_flag(tty->term, TTYC_BCE))
		return (0);
	if (!COLOUR_DEFAULT(bg) || !COLOUR_DEFAULT(gc->bg))
		return (1);
	return (0);
}

/*
 * Redraw scroll region using data from screen (already updated). Used when
 * CSR not supported, or window is a pane that doesn't take up the full
 * width of the terminal.
 */
static void
tty_redraw_region(struct tty *tty, const struct tty_ctx *ctx)
{
	struct client		*c = tty->client;
	u_int			 i;

	/*
	 * If region is large, schedule a redraw. In most cases this is likely
	 * to be followed by some more scrolling.
	 */
	if (tty_large_region(tty, ctx) || ctx->flags & TTY_CTX_PANE_OBSCURED) {
		log_debug("%s: %s large region redraw", __func__, c->name);
		ctx->redraw_cb(ctx);
		return;
	}

	log_debug("%s: %s small region redraw (%u-%u)", __func__, c->name,
	    ctx->orupper, ctx->orlower);
	for (i = ctx->orupper; i <= ctx->orlower; i++)
		tty_draw_pane(tty, ctx, i);
}

/* Is this position visible in the pane? */
static int
tty_is_visible(__unused struct tty *tty, const struct tty_ctx *ctx, u_int px,
    u_int py, u_int nx, u_int ny)
{
	u_int	xoff = ctx->rxoff + px, yoff = ctx->ryoff + py;

	if (~ctx->flags & TTY_CTX_WINDOW_BIGGER)
		return (1);

	if (xoff + nx <= ctx->wox || xoff >= ctx->wox + ctx->wsx ||
	    yoff + ny <= ctx->woy || yoff >= ctx->woy + ctx->wsy)
		return (0);
	return (1);
}

/* Clamp line position to visible part of pane. */
static int
tty_clamp_line(struct tty *tty, const struct tty_ctx *ctx, u_int px, u_int py,
    u_int nx, u_int *i, u_int *x, u_int *rx, u_int *ry)
{
	int	xoff = ctx->rxoff + px;

	/*
	 * px = x position in pane
	 * py = y position in pane
	 * nx = width
	 *
	 * i = new x position in pane
	 * x = x position on terminal
	 * rx = new width
	 * ry = y position on terminal
	 */

	if (!tty_is_visible(tty, ctx, px, py, nx, 1))
		return (0);
	*ry = ctx->yoff + py - ctx->woy;

	if (xoff >= (int)ctx->wox && xoff + nx <= ctx->wox + ctx->wsx) {
		/* All visible. */
		*i = 0;
		*x = ctx->xoff + px - ctx->wox;
		*rx = nx;
	} else if (xoff < (int)ctx->wox && xoff + nx > ctx->wox + ctx->wsx) {
		/* Both left and right not visible. */
		*i = ctx->wox;
		*x = 0;
		*rx = ctx->wsx;
	} else if (xoff < (int)ctx->wox) {
		/* Left not visible. */
		*i = ctx->wox - (ctx->xoff + px);
		*x = 0;
		*rx = nx - *i;
	} else {
		/* Right not visible. */
		*i = 0;
		*x = (ctx->xoff + px) - ctx->wox;
		*rx = ctx->wsx - *x;
	}
	if (*rx > nx)
		fatalx("%s: x too big, %u > %u", __func__, *rx, nx);

	return (1);
}

/* Clear a line. */
static void
tty_clear_line(struct tty *tty, const struct grid_cell *defaults, u_int py,
    u_int px, u_int nx, u_int bg)
{
	struct client		*c = tty->client;

	log_debug("%s: %s, %u at %u,%u", __func__, c->name, nx, px, py);

	/* Nothing to clear. */
	if (nx == 0)
		return;

	/* If genuine BCE is available, can try escape sequences. */
	if (!tty_fake_bce(tty, defaults, bg)) {
		/*
		 * The whole line the terminal is waiting to wrap at the end
		 * of: EL 2 there, without moving the cursor, which would end
		 * the wait - the next character may still wrap from this line.
		 * Not while a scroll is owed: this line is not scrolled in yet.
		 */
		if (px == 0 && nx >= tty->sx && py == tty->cy &&
		    tty->cx >= tty->sx && (~tty->flags & TTY_OWESCROLL) &&
		    (tty->term->flags & TERM_VT100LIKE)) {
			tty_puts(tty, "\033[2K");
			return;
		}

		/* Off the end of the line, use EL if available. */
		if (px + nx >= tty->sx && tty_term_has(tty->term, TTYC_EL)) {
			tty_cursor(tty, px, py);
			tty_putcode(tty, TTYC_EL);
			return;
		}

		/* At the start of the line. Use EL1. */
		if (px == 0 && tty_term_has(tty->term, TTYC_EL1)) {
			tty_cursor(tty, px + nx - 1, py);
			tty_putcode(tty, TTYC_EL1);
			return;
		}

		/* Section of line. Use ECH if possible. */
		if (tty_term_has(tty->term, TTYC_ECH)) {
			tty_cursor(tty, px, py);
			tty_putcode_i(tty, TTYC_ECH, nx);
			return;
		}
	}

	/* Couldn't use an escape sequence, use spaces. */
	tty_cursor(tty, px, py);
	tty_repeat_space(tty, nx);
}

/* Clear a line, adjusting to visible part of pane. */
static void
tty_clear_pane_line(struct tty *tty, const struct tty_ctx *ctx, u_int py,
    u_int px, u_int nx, u_int bg)
{
	struct client		*c = tty->client;
	u_int			 l, x, rx, ry;

	log_debug("%s: %s, %u at %u,%u", __func__, c->name, nx, px, py);

	if (tty_clamp_line(tty, ctx, px, py, nx, &l, &x, &rx, &ry))
		tty_clear_line(tty, &ctx->defaults, ry, x, rx, bg);
}

/* Clamp area position to visible part of pane. */
static int
tty_clamp_area(struct tty *tty, const struct tty_ctx *ctx, u_int px, u_int py,
    u_int nx, u_int ny, u_int *i, u_int *j, u_int *x, u_int *y, u_int *rx,
    u_int *ry)
{
	u_int	xoff = ctx->rxoff + px, yoff = ctx->ryoff + py;

	if (!tty_is_visible(tty, ctx, px, py, nx, ny))
		return (0);

	if (xoff >= ctx->wox && xoff + nx <= ctx->wox + ctx->wsx) {
		/* All visible. */
		*i = 0;
		*x = ctx->xoff + px - ctx->wox;
		*rx = nx;
	} else if (xoff < ctx->wox && xoff + nx > ctx->wox + ctx->wsx) {
		/* Both left and right not visible. */
		*i = ctx->wox;
		*x = 0;
		*rx = ctx->wsx;
	} else if (xoff < ctx->wox) {
		/* Left not visible. */
		*i = ctx->wox - (ctx->xoff + px);
		*x = 0;
		*rx = nx - *i;
	} else {
		/* Right not visible. */
		*i = 0;
		*x = (ctx->xoff + px) - ctx->wox;
		*rx = ctx->wsx - *x;
	}
	if (*rx > nx)
		fatalx("%s: x too big, %u > %u", __func__, *rx, nx);

	if (yoff >= ctx->woy && yoff + ny <= ctx->woy + ctx->wsy) {
		/* All visible. */
		*j = 0;
		*y = ctx->yoff + py - ctx->woy;
		*ry = ny;
	} else if (yoff < ctx->woy && yoff + ny > ctx->woy + ctx->wsy) {
		/* Both top and bottom not visible. */
		*j = ctx->woy;
		*y = 0;
		*ry = ctx->wsy;
	} else if (yoff < ctx->woy) {
		/* Top not visible. */
		*j = ctx->woy - (ctx->yoff + py);
		*y = 0;
		*ry = ny - *j;
	} else {
		/* Bottom not visible. */
		*j = 0;
		*y = (ctx->yoff + py) - ctx->woy;
		*ry = ctx->wsy - *y;
	}
	if (*ry > ny)
		fatalx("%s: y too big, %u > %u", __func__, *ry, ny);

	return (1);
}

/* Clear an area, adjusting to visible part of pane. */
static void
tty_clear_area(struct tty *tty, const struct tty_ctx *ctx, u_int py,
    u_int ny, u_int px, u_int nx, u_int bg)
{
	struct client		*c = tty->client;
	const struct grid_cell	*defaults = &ctx->defaults;
	u_int			 yy;
	char			 tmp[64];
	int			 scroll;

	log_debug("%s: %s, %u,%u at %u,%u", __func__, c->name, nx, ny, px, py);

	/*
	 * Scrolling lines away clears them - but a terminal keeping its own
	 * scrollback (clear-on-attach off, on its primary screen) may keep
	 * lines scrolled off the top of a region at the top of the screen
	 * (xterm, iTerm2), putting what was erased into its scrollback.
	 */
	scroll = (py != 0 || (tty->flags & TTY_ALTSCREEN) || clear_on_attach);

	/* Nothing to clear. */
	if (nx == 0 || ny == 0)
		return;

	/* If BCE is available, can try to clear as a region. */
	if (!tty_fake_bce(tty, defaults, bg)) {
		/* Use ED if clearing off the bottom of the terminal. */
		if (px == 0 &&
		    px + nx >= tty->sx &&
		    py + ny >= tty->sy &&
		    tty_term_has(tty->term, TTYC_ED)) {
			tty_cursor(tty, 0, py);
			tty_putcode(tty, TTYC_ED);
			return;
		}

		/*
		 * On VT420 compatible terminals we can use DECFRA if the
		 * background colour isn't default (because it doesn't work
		 * after SGR 0).
		 */
		if ((tty->term->flags & TERM_DECFRA) && !COLOUR_DEFAULT(bg)) {
			xsnprintf(tmp, sizeof tmp, "\033[32;%u;%u;%u;%u$x",
			    py + 1, px + 1, py + ny, px + nx);
			tty_puts(tty, tmp);
			return;
		}

		/* Full lines can be scrolled away to clear them. */
		if (scroll &&
		    px == 0 &&
		    px + nx >= tty->sx &&
		    ny > 2 &&
		    tty_term_has(tty->term, TTYC_CSR) &&
		    tty_term_has(tty->term, TTYC_INDN)) {
			tty_region(tty, py, py + ny - 1);
			tty_margin_off(tty);
			tty_putcode_i(tty, TTYC_INDN, ny);
			return;
		}

		/*
		 * If margins are supported, can just scroll the area off to
		 * clear it.
		 */
		if (scroll &&
		    nx > 2 &&
		    ny > 2 &&
		    tty_term_has(tty->term, TTYC_CSR) &&
		    tty_use_margin(tty) &&
		    tty_term_has(tty->term, TTYC_INDN)) {
			tty_region(tty, py, py + ny - 1);
			tty_margin(tty, px, px + nx - 1);
			tty_putcode_i(tty, TTYC_INDN, ny);
			return;
		}
	}

	/* Couldn't use an escape sequence, loop over the lines. */
	for (yy = py; yy < py + ny; yy++)
		tty_clear_line(tty, defaults, yy, px, nx, bg);
}

/* Clear an area in a pane. */
static void
tty_clear_pane_area(struct tty *tty, const struct tty_ctx *ctx, u_int py,
    u_int ny, u_int px, u_int nx, u_int bg)
{
	u_int	i, j, x, y, rx, ry;

	if (tty_clamp_area(tty, ctx, px, py, nx, ny, &i, &j, &x, &y, &rx, &ry))
		tty_clear_area(tty, ctx, y, ry, x, rx, bg);
}

/* Redraw a line of a screen at py. */
static void
tty_draw_pane(struct tty *tty, const struct tty_ctx *ctx, u_int py)
{
	struct screen		*s = ctx->s;
	u_int			 nx = ctx->sx, i, x, rx, ry;

	log_debug("%s: %s %u", __func__, tty->client->name, py);

	if (~ctx->flags & TTY_CTX_WINDOW_BIGGER) {
		tty_draw_line(tty, s, 0, py, nx, ctx->xoff, ctx->yoff + py,
		    &ctx->style_ctx);
		return;
	}
	if (tty_clamp_line(tty, ctx, 0, py, nx, &i, &x, &rx, &ry))
		tty_draw_line(tty, s, i, py, rx, x, ry, &ctx->style_ctx);
}

void
tty_cmd_redrawline(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int			 i, x, rx, ry;

	if (tty_clamp_line(tty, ctx, ctx->ocx, ctx->ocy, ctx->n,
	    &i, &x, &rx, &ry))
		tty_draw_line(tty, ctx->s, ctx->ocx + i, ctx->ocy, rx, x, ry,
		    &ctx->style_ctx);
}

/* Check if character needs to be mapped for codeset. */
const struct grid_cell *
tty_check_codeset(struct tty *tty, const struct grid_cell *gc)
{
	static struct grid_cell	new;
	int			c;

	/* Characters less than 0x7f are always fine, no matter what. */
	if (gc->data.size == 1 && *gc->data.data < 0x7f)
		return (gc);
	if (gc->flags & GRID_FLAG_TAB)
		return (gc);

	/* UTF-8 terminal and a UTF-8 character - fine. */
	if (tty->client->flags & CLIENT_UTF8)
		return (gc);
	memcpy(&new, gc, sizeof new);

	/* See if this can be mapped to an ACS character. */
	c = tty_acs_reverse_get(tty, gc->data.data, gc->data.size);
	if (c != -1) {
		utf8_set(&new.data, c);
		new.attr |= GRID_ATTR_CHARSET;
		return (&new);
	}

	/* Replace by the right number of underscores. */
	new.data.size = gc->data.width;
	if (new.data.size > UTF8_SIZE)
		new.data.size = UTF8_SIZE;
	memset(new.data.data, '_', new.data.size);
	return (&new);
}

#ifdef ENABLE_SIXEL
/* Update context for client. */
static int
tty_set_client_cb(struct tty_ctx *ttyctx, struct client *c)
{
	struct window_pane	*wp = ttyctx->arg;

	if (c->session->curw->window != wp->window)
		return (0);
	if (wp->layout_cell == NULL)
		return (0);

	if (tty_window_offset(&c->tty, &ttyctx->wox, &ttyctx->woy, &ttyctx->wsx,
	    &ttyctx->wsy))
		ttyctx->flags |= TTY_CTX_WINDOW_BIGGER;
	else
		ttyctx->flags &= ~TTY_CTX_WINDOW_BIGGER;

	ttyctx->yoff = ttyctx->ryoff = wp->yoff;
	if (status_at_line(c) == 0)
		ttyctx->yoff += status_line_size(c);

	return (1);
}

void
tty_draw_images(struct client *c, struct window_pane *wp)
{
	struct image	*im;
	struct tty_ctx	 ttyctx;

	TAILQ_FOREACH(im, &wp->screen->images, entry) {
		memset(&ttyctx, 0, sizeof ttyctx);

		/* Set the client independent properties. */
		ttyctx.ocx = im->px;
		ttyctx.ocy = im->py;

		ttyctx.orlower = wp->screen->rlower;
		ttyctx.orupper = wp->screen->rupper;

		ttyctx.xoff = ttyctx.rxoff = wp->xoff;
		ttyctx.sx = wp->sx;
		ttyctx.sy = wp->sy;

		ttyctx.image = im;
		ttyctx.arg = wp;
		ttyctx.set_client_cb = tty_set_client_cb;
		ttyctx.flags |= TTY_CTX_INVISIBLE_PANES;
		tty_write_one(tty_cmd_sixelimage, c, &ttyctx);
	}
}
#endif

void
tty_sync_start(struct tty *tty)
{
	if (tty->flags & TTY_BLOCK)
		return;
	if (tty->flags & TTY_SYNCING)
		return;
	tty->flags |= TTY_SYNCING;

	if (tty_term_has(tty->term, TTYC_SYNC)) {
		log_debug("%s sync start", tty->client->name);
		tty_putcode_i(tty, TTYC_SYNC, 1);
	}
}

void
tty_sync_end(struct tty *tty)
{
	if (tty->flags & TTY_BLOCK)
		return;
	if (~tty->flags & TTY_SYNCING)
		return;
	tty->flags &= ~TTY_SYNCING;

	if (tty_term_has(tty->term, TTYC_SYNC)) {
		log_debug("%s sync end", tty->client->name);
		tty_putcode_i(tty, TTYC_SYNC, 2);
	}
}

static int
tty_client_ready(const struct tty_ctx *ctx, struct client *c)
{
	if (c->session == NULL || c->tty.term == NULL)
		return (0);
	if (c->flags & CLIENT_SUSPENDED)
		return (0);

	/*
	 * If invisible panes are allowed (used for passthrough), don't care if
	 * redrawing or frozen.
	 */
	if (ctx->flags & TTY_CTX_INVISIBLE_PANES)
		return (1);

	if (c->flags & CLIENT_REDRAWWINDOW)
		return (0);
	if (c->tty.flags & TTY_FREEZE)
		return (0);
	return (1);
}

void
tty_write(void (*cmdfn)(struct tty *, const struct tty_ctx *),
    struct tty_ctx *ctx)
{
	struct client	*c;
	int		 state;

	if (ctx->set_client_cb == NULL)
		return;
	TAILQ_FOREACH(c, &clients, entry) {
		/* The terminal has the pane's output as written. */
		if (ctx->wp != NULL && c->forward_pane == ctx->wp->id)
			continue;
		if (tty_client_ready(ctx, c)) {
			state = ctx->set_client_cb(ctx, c);
			if (state == -1)
				break;
			if (state == 0)
				continue;
			cmdfn(&c->tty, ctx);
		}
	}
}

#ifdef ENABLE_SIXEL
/* Only write to the incoming tty instead of every client. */
static void
tty_write_one(void (*cmdfn)(struct tty *, const struct tty_ctx *),
    struct client *c, struct tty_ctx *ctx)
{
	if (ctx->set_client_cb == NULL)
		return;
	if ((ctx->set_client_cb(ctx, c)) == 1)
		cmdfn(&c->tty, ctx);
}
#endif

void
tty_cmd_insertcharacter(struct tty *tty, const struct tty_ctx *ctx)
{
	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    !tty_full_width(tty, ctx) ||
	    tty_fake_bce(tty, &ctx->defaults, ctx->bg) ||
	    (!tty_term_has(tty->term, TTYC_ICH) &&
	    !tty_term_has(tty->term, TTYC_ICH1))) {
		tty_draw_pane(tty, ctx, ctx->ocy);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->ocy);

	tty_emulate_repeat(tty, TTYC_ICH, TTYC_ICH1, ctx->n);
}

void
tty_cmd_deletecharacter(struct tty *tty, const struct tty_ctx *ctx)
{
	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    !tty_full_width(tty, ctx) ||
	    tty_fake_bce(tty, &ctx->defaults, ctx->bg) ||
	    (!tty_term_has(tty->term, TTYC_DCH) &&
	    !tty_term_has(tty->term, TTYC_DCH1))) {
		tty_draw_pane(tty, ctx, ctx->ocy);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->ocy);

	tty_emulate_repeat(tty, TTYC_DCH, TTYC_DCH1, ctx->n);
}

void
tty_cmd_clearcharacter(struct tty *tty, const struct tty_ctx *ctx)
{
	/*
	 * A row a scroll brought in: the terminal's scroll brought it in blank
	 * with the same background, unless tmux must draw backgrounds itself.
	 * Clearing it again is not what the program sent, and clearing a
	 * whole row tells some terminals (tmux) the row above no longer
	 * wraps into it.
	 */
	if ((ctx->flags & TTY_CTX_SCROLLEDIN) &&
	    !tty_fake_bce(tty, &ctx->defaults, ctx->bg))
		return;

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_clear_pane_line(tty, ctx, ctx->ocy, ctx->ocx, ctx->n, ctx->bg);
}

void
tty_cmd_insertline(struct tty *tty, const struct tty_ctx *ctx)
{
	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    !tty_full_width(tty, ctx) ||
	    tty_fake_bce(tty, &ctx->defaults, ctx->bg) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    !tty_term_has(tty->term, TTYC_IL1) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_off(tty);
	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->ocy);

	tty_emulate_repeat(tty, TTYC_IL, TTYC_IL1, ctx->n);
	tty->cx = tty->cy = UINT_MAX;
}

void
tty_cmd_deleteline(struct tty *tty, const struct tty_ctx *ctx)
{
	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    !tty_full_width(tty, ctx) ||
	    tty_fake_bce(tty, &ctx->defaults, ctx->bg) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    !tty_term_has(tty->term, TTYC_DL1) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_off(tty);
	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->ocy);

	tty_emulate_repeat(tty, TTYC_DL, TTYC_DL1, ctx->n);
	tty->cx = tty->cy = UINT_MAX;
}

void
tty_cmd_clearline(struct tty *tty, const struct tty_ctx *ctx)
{
	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_clear_pane_line(tty, ctx, ctx->ocy, 0, ctx->sx, ctx->bg);
}

void
tty_cmd_clearendofline(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int	nx = ctx->sx - ctx->ocx;

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_clear_pane_line(tty, ctx, ctx->ocy, ctx->ocx, nx, ctx->bg);
}

void
tty_cmd_clearstartofline(struct tty *tty, const struct tty_ctx *ctx)
{
	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_clear_pane_line(tty, ctx, ctx->ocy, 0, ctx->ocx + 1, ctx->bg);
}

void
tty_cmd_reverseindex(struct tty *tty, const struct tty_ctx *ctx)
{
	if (ctx->ocy != ctx->orupper)
		return;

	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    (!tty_full_width(tty, ctx) && !tty_use_margin(tty)) ||
	    tty_fake_bce(tty, &ctx->defaults, 8) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    (!tty_term_has(tty->term, TTYC_RI) &&
	    !tty_term_has(tty->term, TTYC_RIN)) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_pane(tty, ctx);
	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->orupper);

	if (tty_term_has(tty->term, TTYC_RI))
		tty_putcode(tty, TTYC_RI);
	else
		tty_putcode_i(tty, TTYC_RIN, 1);
}

void
tty_cmd_linefeed(struct tty *tty, const struct tty_ctx *ctx)
{
	if (ctx->ocy != ctx->orlower)
		return;

	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    (!tty_full_width(tty, ctx) && !tty_use_margin(tty)) ||
	    tty_fake_bce(tty, &ctx->defaults, 8) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_pane(tty, ctx);

	/*
	 * If we want to wrap a pane while using margins, the cursor needs to
	 * be exactly on the right of the region. If the cursor is entirely off
	 * the edge - move it back to the right. Some terminals are funny about
	 * this and insert extra spaces, so only use the right if margins are
	 * enabled.
	 */
	if (ctx->xoff + ctx->ocx > tty->rright) {
		if (!tty_use_margin(tty))
			tty_cursor(tty, 0, ctx->yoff + ctx->ocy);
		else
			tty_cursor(tty, tty->rright, ctx->yoff + ctx->ocy);
	} else
		tty_cursor_pane(tty, ctx, ctx->ocx, ctx->ocy);

	tty_putc(tty, '\n');
}

void
tty_cmd_scrollup(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int			 i;

	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    (!tty_full_width(tty, ctx) && !tty_use_margin(tty)) ||
	    tty_fake_bce(tty, &ctx->defaults, 8) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_count_history(tty, ctx);

	/* A scroll still owed happens first. */
	tty_pay_scroll(tty);
	tty->flags &= ~TTY_WRAPPED0;

	/*
	 * A line wrapping from the bottom row, and the terminal is waiting to
	 * wrap there: leave the scroll to it. The next character wraps and
	 * scrolls, and the terminal knows the row continues the one above -
	 * so selecting it or reflowing on resize keeps the line whole, as
	 * without tmux. Anything else written first pays the scroll.
	 */
	if ((ctx->flags & TTY_CTX_WRAPPED) &&
	    ctx->n == 1 &&
	    ctx->bg == 8 &&
	    tty_full_width(tty, ctx) &&
	    (~tty->term->flags & TERM_NOAM) &&
	    (!tty_use_margin(tty) ||
	    (tty->rleft == 0 && tty->rright == tty->sx - 1)) &&
	    tty->rupper == ctx->yoff + ctx->orupper - ctx->woy &&
	    tty->rlower == ctx->yoff + ctx->orlower - ctx->woy &&
	    tty->cy == tty->rlower &&
	    (tty->cx >= tty->sx ||
	    ((ctx->flags & TTY_CTX_WRAPWIDE) && tty->cx == tty->sx - 1))) {
		log_debug("%s: scroll left to the wrap at %u", __func__,
		    tty->cy);
		tty->flags |= TTY_OWESCROLL;
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_pane(tty, ctx);

	if (ctx->n == 1 || !tty_term_has(tty->term, TTYC_INDN)) {
		if (!tty_use_margin(tty))
			tty_cursor(tty, 0, tty->rlower);
		else
			tty_cursor(tty, tty->rright, tty->rlower);
		for (i = 0; i < ctx->n; i++)
			tty_putc(tty, '\n');
	} else {
		if (tty->cy == UINT_MAX)
			tty_cursor(tty, 0, 0);
		else
			tty_cursor(tty, 0, tty->cy);
		tty_putcode_i(tty, TTYC_INDN, ctx->n);
	}
}

void
tty_cmd_scrolldown(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int		 i;

	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) ||
	    (!tty_full_width(tty, ctx) && !tty_use_margin(tty)) ||
	    tty_fake_bce(tty, &ctx->defaults, 8) ||
	    !tty_term_has(tty->term, TTYC_CSR) ||
	    (!tty_term_has(tty->term, TTYC_RI) &&
	    !tty_term_has(tty->term, TTYC_RIN)) ||
	    ctx->sx == 1 ||
	    ctx->sy == 1) {
		tty_redraw_region(tty, ctx);
		return;
	}

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_margin_pane(tty, ctx);
	tty_cursor_pane(tty, ctx, ctx->ocx, ctx->orupper);

	if (tty_term_has(tty->term, TTYC_RIN))
		tty_putcode_i(tty, TTYC_RIN, ctx->n);
	else {
		for (i = 0; i < ctx->n; i++)
			tty_putcode(tty, TTYC_RI);
	}
}

/*
 * Whether a clear of a whole pane goes to the terminal as the application
 * sent it: the pane is the whole terminal and keeps its scrollback, where the
 * terminal may move what is cleared - for some clears and not others. Lines
 * the pane's history took from the clear then count as reaching it.
 */
static int
tty_clear_as_sent(struct tty *tty, const struct tty_ctx *ctx)
{
	struct window_pane	*wp = ctx->wp;

	if (!tty_pane_is_terminal(tty, wp) || ctx->s != &wp->base)
		return (0);
	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) || tty_pane_covered(wp) ||
	    tty_fake_bce(tty, &ctx->defaults, ctx->bg))
		return (0);
	return (tty_term_has(tty->term, TTYC_ED));
}

void
tty_cmd_clearendofscreen(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int	px, py, nx, ny;

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, 0, ctx->sy - 1);
	tty_margin_off(tty);

	if (ctx->ocx == 0 && ctx->ocy == 0 && tty_clear_as_sent(tty, ctx)) {
		tty_cursor(tty, 0, 0);
		tty_putcode(tty, TTYC_ED);
		tty_count_history(tty, ctx);
		return;
	}

	px = 0;
	nx = ctx->sx;
	py = ctx->ocy + 1;
	ny = ctx->sy - ctx->ocy - 1;

	tty_clear_pane_area(tty, ctx, py, ny, px, nx, ctx->bg);

	px = ctx->ocx;
	nx = ctx->sx - ctx->ocx;
	py = ctx->ocy;

	tty_clear_pane_line(tty, ctx, py, px, nx, ctx->bg);
}

void
tty_cmd_clearstartofscreen(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int	px, py, nx, ny;

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, 0, ctx->sy - 1);
	tty_margin_off(tty);

	px = 0;
	nx = ctx->sx;
	py = 0;
	ny = ctx->ocy;

	tty_clear_pane_area(tty, ctx, py, ny, px, nx, ctx->bg);

	px = 0;
	nx = ctx->ocx + 1;
	py = ctx->ocy;

	tty_clear_pane_line(tty, ctx, py, px, nx, ctx->bg);
}

void
tty_cmd_clearscreen(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int	px, py, nx, ny;

	tty_default_attributes(tty, ctx->bg, &ctx->style_ctx);

	tty_region_pane(tty, ctx, 0, ctx->sy - 1);
	tty_margin_off(tty);

	/* ED 2 itself: the clear capability may erase the scrollback too. */
	if ((tty->term->flags & TERM_VT100LIKE) &&
	    tty_clear_as_sent(tty, ctx)) {
		tty_puts(tty, "\033[2J");
		tty_count_history(tty, ctx);
		return;
	}

	px = 0;
	nx = ctx->sx;
	py = 0;
	ny = ctx->sy;

	tty_clear_pane_area(tty, ctx, py, ny, px, nx, ctx->bg);
}

void
tty_cmd_alignmenttest(struct tty *tty, const struct tty_ctx *ctx)
{
	u_int		 i, j;

	if (ctx->flags & TTY_CTX_WINDOW_BIGGER) {
		ctx->redraw_cb(ctx);
		return;
	}

	tty_attributes(tty, &grid_default_cell, &ctx->style_ctx);

	tty_region_pane(tty, ctx, 0, ctx->sy - 1);
	tty_margin_off(tty);

	for (j = 0; j < ctx->sy; j++) {
		tty_cursor_pane(tty, ctx, 0, j);
		for (i = 0; i < ctx->sx; i++)
			tty_putc(tty, 'E');
	}
}

void
tty_cmd_cell(struct tty *tty, const struct tty_ctx *ctx)
{
	if (!tty_is_visible(tty, ctx, ctx->ocx, ctx->ocy, 1, 1))
		return;

	if (ctx->xoff + ctx->ocx - ctx->wox > tty->sx - 1 &&
	    ctx->ocy == ctx->orlower &&
	    tty_full_width(tty, ctx))
		tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);

	tty_margin_off(tty);
	if (ctx->flags & TTY_CTX_CELL_INVALIDATE)
		tty_invalidate(tty);
	tty_cursor_pane_unless_wrap(tty, ctx, ctx->ocx, ctx->ocy);

	tty_cell(tty, ctx->cell, &ctx->style_ctx);

	if (ctx->flags & TTY_CTX_CELL_INVALIDATE)
		tty_invalidate(tty);
}

void
tty_cmd_cells(struct tty *tty, const struct tty_ctx *ctx)
{
	const char		*cp = ctx->data.data;
	size_t			 n = ctx->data.size;

	if (!tty_is_visible(tty, ctx, ctx->ocx, ctx->ocy, n, 1))
		return;

	if ((ctx->flags & TTY_CTX_WINDOW_BIGGER) &&
	    (ctx->xoff + ctx->ocx < ctx->wox ||
	    ctx->xoff + ctx->ocx + n > ctx->wox + ctx->wsx)) {
		if ((~ctx->flags & TTY_CTX_WRAPPED) ||
		    !tty_full_width(tty, ctx) ||
		    (tty->term->flags & TERM_NOAM) ||
		    ctx->xoff + ctx->ocx != 0 ||
		    ctx->yoff + ctx->ocy != tty->cy + 1 ||
		    tty->cx < tty->sx ||
		    tty->cy == tty->rlower)
			tty_draw_pane(tty, ctx, ctx->ocy);
		else
			ctx->redraw_cb(ctx);
		return;
	}

	tty_margin_off(tty);
	tty_cursor_pane_unless_wrap(tty, ctx, ctx->ocx, ctx->ocy);
	tty_attributes(tty, ctx->cell, &ctx->style_ctx);
	tty_putn(tty, cp, n, n);
}

void
tty_cmd_setselection(struct tty *tty, const struct tty_ctx *ctx)
{
	tty_set_selection(tty, ctx->sel.clip, ctx->sel.data, ctx->sel.size);
}

void
tty_set_selection(struct tty *tty, const char *clip, const char *buf,
    size_t len)
{
	char	*encoded;
	size_t	 size;

	if (~tty->flags & TTY_STARTED)
		return;
	if (!tty_term_has(tty->term, TTYC_MS))
		return;

	size = 4 * ((len + 2) / 3) + 1; /* storage for base64 */
	encoded = xmalloc(size);

	b64_ntop(buf, len, encoded, size);
	tty->flags |= TTY_NOBLOCK;
	tty_putcode_ss(tty, TTYC_MS, clip, encoded);

	free(encoded);
}

void
tty_cmd_rawstring(struct tty *tty, const struct tty_ctx *ctx)
{
	tty->flags |= TTY_NOBLOCK;
	tty_add(tty, ctx->data.data, ctx->data.size);
	tty_invalidate(tty);
}

#ifdef ENABLE_SIXEL
void
tty_cmd_sixelimage(struct tty *tty, const struct tty_ctx *ctx)
{
	struct image		*im = ctx->image;
	struct sixel_image	*si = im->data;
	struct sixel_image	*new;
	char			*data;
	size_t			 size;
	u_int			 cx = ctx->ocx, cy = ctx->ocy, sx, sy;
	u_int			 i, j, x, y, rx, ry;
	int			 fallback = 0;

	if ((~tty->term->flags & TERM_SIXEL) &&
            !tty_term_has(tty->term, TTYC_SXL))
		fallback = 1;
	if (tty->xpixel == 0 || tty->ypixel == 0)
		fallback = 1;

	sixel_size_in_cells(si, &sx, &sy);
	log_debug("%s: image is %ux%u", __func__, sx, sy);
	if (!tty_clamp_area(tty, ctx, cx, cy, sx, sy, &i, &j, &x, &y, &rx, &ry))
		return;
	log_debug("%s: clamping to %u,%u-%u,%u", __func__, i, j, rx, ry);

	if (fallback == 1) {
		data = xstrdup(im->fallback);
		size = strlen(data);
	} else {
		new = sixel_scale(si, tty->xpixel, tty->ypixel, i, j, rx, ry, 0);
		if (new == NULL)
			return;

		data = sixel_print(new, si, &size);
	}
	if (data != NULL) {
		log_debug("%s: %zu bytes: %s", __func__, size, data);
		tty_region_off(tty);
		tty_margin_off(tty);
		tty_cursor(tty, x, y);

		tty->flags |= TTY_NOBLOCK;
		tty_add(tty, data, size);
		tty_invalidate(tty);
		free(data);
	}

	if (fallback == 0)
		sixel_free(new);
}
#endif

void
tty_cmd_syncstart(struct tty *tty, const struct tty_ctx *ctx)
{
	if (ctx->flags & TTY_CTX_SYNC)
		tty_sync_start(tty);
}

void
tty_cell(struct tty *tty, const struct grid_cell *gc,
    const struct tty_style_ctx *style_ctx)
{
	const struct grid_cell	*gcp;
	u_int			 ocx;

	/* Skip last character if terminal is stupid. */
	if ((tty->term->flags & TERM_NOAM) &&
	    tty->cy == tty->sy - 1 &&
	    tty->cx == tty->sx - 1)
		return;

	/* If this is a padding character, do nothing. */
	if (gc->flags & GRID_FLAG_PADDING)
		return;

	/* Check the output codeset and apply attributes. */
	gcp = tty_check_codeset(tty, gc);
	tty_attributes(tty, gcp, style_ctx);

	/* If it is a single character, write with putc to handle ACS. */
	if (gcp->data.size == 1) {
		if (*gcp->data.data < 0x20 || *gcp->data.data == 0x7f)
			return;
		tty_putc(tty, *gcp->data.data);
		return;
	}

	/*
	 * Write the data. A wide character that does not fit in the last
	 * column wraps whole: the cursor ends after it on the next line.
	 */
	ocx = tty->cx;
	tty_putn(tty, gcp->data.data, gcp->data.size, gcp->data.width);
	if (gcp->data.width > 1 && ocx < tty->sx &&
	    ocx + gcp->data.width > tty->sx && tty->cx != UINT_MAX)
		tty->cx = gcp->data.width;
}

void
tty_reset(struct tty *tty)
{
	struct grid_cell	*gc = &tty->cell;

	if (!grid_cells_equal(gc, &grid_default_cell)) {
		if (gc->link != 0)
			tty_putcode_ss(tty, TTYC_HLS, "", "");
		if ((gc->attr & GRID_ATTR_CHARSET) && tty_acs_needed(tty))
			tty_putcode(tty, TTYC_RMACS);
		tty_putcode(tty, TTYC_SGR0);
		memcpy(gc, &grid_default_cell, sizeof *gc);
	}
	memcpy(&tty->last_cell, &grid_default_cell, sizeof tty->last_cell);
}

void
tty_invalidate(struct tty *tty)
{
	if (tty->flags & TTY_STARTED)
		tty_pay_scroll(tty);
	tty->flags &= ~TTY_OWESCROLL;
	memcpy(&tty->cell, &grid_default_cell, sizeof tty->cell);
	memcpy(&tty->last_cell, &grid_default_cell, sizeof tty->last_cell);

	tty->cx = tty->cy = UINT_MAX;
	tty->rupper = tty->rleft = UINT_MAX;
	tty->rlower = tty->rright = UINT_MAX;

	/*
	 * Forwarding (forward.c): the program's own output has the cursor,
	 * region, margins and attributes where it wants them - on a resize,
	 * a feature update or anything else, only forget them and set tmux's
	 * own modes again. forward_stop sets them all when drawing resumes.
	 */
	if (tty->client->forward_pane != UINT_MAX) {
		if (tty->flags & TTY_STARTED) {
			tty->mode = ALL_MODES;
			tty_update_mode(tty, MODE_CURSOR, NULL);
		}
		return;
	}

	if (tty->flags & TTY_STARTED) {
		if (tty_use_margin(tty))
			tty_putcode(tty, TTYC_ENMG);
		tty_putcode(tty, TTYC_SGR0);

		tty->mode = ALL_MODES;
		tty_update_mode(tty, MODE_CURSOR, NULL);

		tty_cursor(tty, 0, 0);
		tty_region_off(tty);
		tty_margin_off(tty);
	} else
		tty->mode = MODE_CURSOR;
}

/* Turn off margin. */
void
tty_region_off(struct tty *tty)
{
	tty_region(tty, 0, tty->sy - 1);
}

/* Set region inside pane. */
static void
tty_region_pane(struct tty *tty, const struct tty_ctx *ctx, u_int rupper,
    u_int rlower)
{
	tty_region(tty, ctx->yoff + rupper - ctx->woy,
	    ctx->yoff + rlower - ctx->woy);
}

/* Set region at absolute position. */
static void
tty_region(struct tty *tty, u_int rupper, u_int rlower)
{
	if (tty->rlower == rlower && tty->rupper == rupper)
		return;
	if (!tty_term_has(tty->term, TTYC_CSR))
		return;
	tty_pay_scroll(tty);

	tty->rupper = rupper;
	tty->rlower = rlower;

	/*
	 * Some terminals (such as PuTTY) do not correctly reset the cursor to
	 * 0,0 if it is beyond the last column (they do not reset their wrap
	 * flag so further output causes a line feed). As a workaround, do an
	 * explicit move to 0 first.
	 */
	if (tty->cx >= tty->sx) {
		if (tty->cy == UINT_MAX)
			tty_cursor(tty, 0, 0);
		else
			tty_cursor(tty, 0, tty->cy);
	}

	tty_putcode_ii(tty, TTYC_CSR, tty->rupper, tty->rlower);
	tty->cx = tty->cy = UINT_MAX;
}

/* Turn off margin. */
void
tty_margin_off(struct tty *tty)
{
	tty_margin(tty, 0, tty->sx - 1);
}

/* Set margin inside pane. */
static void
tty_margin_pane(struct tty *tty, const struct tty_ctx *ctx)
{
	int	l, r;

	l = ctx->xoff - ctx->wox;
	r = ctx->xoff + ctx->sx - 1 - ctx->wox;

	if (l < 0)
		l = 0;
	if (l > (int)ctx->wsx)
		l = ctx->wsx;
	if (r < 0)
		r = 0;
	if (r > (int)ctx->wsx)
		r = ctx->wsx;

	tty_margin(tty, l, r);
}

/* Set margin at absolute position. */
static void
tty_margin(struct tty *tty, u_int rleft, u_int rright)
{
	if (!tty_use_margin(tty))
		return;
	if (tty->rleft == rleft && tty->rright == rright)
		return;
	tty_pay_scroll(tty);

	tty_putcode_ii(tty, TTYC_CSR, tty->rupper, tty->rlower);

	tty->rleft = rleft;
	tty->rright = rright;

	if (rleft == 0 && rright == tty->sx - 1)
		tty_putcode(tty, TTYC_CLMG);
	else
		tty_putcode_ii(tty, TTYC_CMG, rleft, rright);
	tty->cx = tty->cy = UINT_MAX;
}

/*
 * Move the cursor, unless it would wrap itself when the next character is
 * printed.
 */
static void
tty_cursor_pane_unless_wrap(struct tty *tty, const struct tty_ctx *ctx,
    u_int cx, u_int cy)
{
	int	next, owed;
	u_int	width = 1;

	/*
	 * The terminal wraps when the next character does not fit: past the
	 * last column, or a wide character in it (as xterm and tmux itself).
	 */
	if (ctx->cell != NULL && ctx->cell->data.width > 1)
		width = ctx->cell->data.width;

	/*
	 * The row below, or - when tty_cmd_scrollup left the scroll to this
	 * wrap - the bottom row itself, which the wrap scrolls up.
	 */
	next = (ctx->yoff + cy == tty->cy + 1 && tty->cy != tty->rlower);
	owed = ((tty->flags & TTY_OWESCROLL) && ctx->yoff + cy == tty->cy &&
	    tty->cy == tty->rlower);
	if ((~ctx->flags & TTY_CTX_WRAPPED) ||
	    !tty_full_width(tty, ctx) ||
	    (tty->term->flags & TERM_NOAM) ||
	    ctx->xoff + cx != 0 ||
	    (!next && !owed) ||
	    tty->cx + width <= tty->sx) {
		if (!tty_rewrap(tty, ctx, cx, cy, width))
			tty_cursor_pane(tty, ctx, cx, cy);
	} else if (owed && ctx->cell != NULL && !COLOUR_DEFAULT(ctx->cell->bg)) {
		/*
		 * The terminal would fill the row the wrap scrolls in with
		 * the character's background: scroll first (still wrapping).
		 */
		tty_pay_scroll(tty);
		tty_cursor_pane(tty, ctx, cx, cy);
	} else {
		/* Setting the character's attributes must not pay the scroll. */
		if (owed)
			tty->flags |= TTY_WRAPNEXT;
		log_debug("%s: will wrap at %u,%u", __func__, tty->cx, tty->cy);
	}
}

/*
 * A line continues from the row above but the terminal is not waiting to
 * wrap at the end of that row (something else was written since, or the
 * rows are drawn out of order). With the terminal keeping its own
 * scrollback, where it decides how lines are selected and reflowed, write
 * the last cell of the row above again - the same cell - so it is, and the
 * continuation wraps there.
 */
static int
tty_rewrap(struct tty *tty, const struct tty_ctx *ctx, u_int cx, u_int cy,
    u_int width)
{
	struct screen		*s = ctx->s;
	struct grid		*gd;
	struct grid_cell	 gc;
	u_int			 x;

	if ((~ctx->flags & TTY_CTX_WRAPPED) || s == NULL || cx != 0 || cy == 0)
		return (0);
	if (!tty_full_width(tty, ctx) || ctx->xoff != 0 ||
	    (tty->term->flags & TERM_NOAM) || (tty->flags & TTY_ALTSCREEN) ||
	    clear_on_attach)
		return (0);
	gd = s->grid;
	if (~grid_get_line(gd, gd->hsize + cy - 1)->flags & GRID_LINE_WRAPPED)
		return (0);
	if ((tty->flags & TTY_WRAPPED0) && tty->cx == 0 &&
	    tty->cy == ctx->yoff + cy - ctx->woy)
		return (1);	/* the terminal wrapped into it already */

	x = screen_size_x(s) - 1;
	grid_view_get_cell(gd, x, cy - 1, &gc);
	if (gc.flags & GRID_FLAG_PADDING) {
		if (x == 0)
			return (0);
		grid_view_get_cell(gd, --x, cy - 1, &gc);
		if (gc.data.width != 2)
			return (0);
	}
	/*
	 * The terminal's scroll region may be left from earlier output: at its
	 * bottom the wrap would scroll it instead of moving down.
	 */
	tty_region_pane(tty, ctx, ctx->orupper, ctx->orlower);
	tty_cursor_pane(tty, ctx, x, cy - 1);
	tty_cell(tty, &gc, &ctx->style_ctx);
	if (tty->cx + width <= tty->sx ||
	    ctx->yoff + cy != tty->cy + 1 || tty->cy == tty->rlower) {
		tty_cursor_pane(tty, ctx, cx, cy);	/* did not work */
		return (1);
	}
	log_debug("%s: will wrap at %u,%u", __func__, tty->cx, tty->cy);
	return (1);
}

/* Move cursor inside pane. */
static void
tty_cursor_pane(struct tty *tty, const struct tty_ctx *ctx, u_int cx, u_int cy)
{
	tty_cursor(tty, ctx->xoff + cx - ctx->wox, ctx->yoff + cy - ctx->woy);
}

/*
 * Start following a pane's history from where it is now, or bring the count
 * of the lines that reached this terminal up to date with the pane's grid.
 *
 * After the grid reflowed its lines once (grid_reflow) while this terminal
 * was behind, the terminal has reflowed what it had too - the pane's lines up
 * to the end of the screen it last drew, a prefix of the pane's - and, as
 * tmux does, kept the end of that on its screen, perhaps pulling rows back
 * from its scrollback: those rows of the pane's history (hist_shown, up to
 * that end) are at the top of its screen already and are only scrolled into
 * its scrollback, not painted over. After anything else that rewrote the
 * history, follow from here.
 */
static void
tty_follow_history(struct tty *tty, struct window_pane *wp)
{
	struct grid		*gd = wp->base.grid;
	struct window_pane	*old;
	u_int			 m, b, end, top;

	if (tty->hist_pane != wp->id) {
		/*
		 * The terminal's scrollback ends with the last history line of
		 * the pane it followed until now; remember whether that line
		 * wraps on to the screen, for tty_forget_wraps.
		 */
		old = window_pane_find_by_id(tty->hist_pane);
		tty->hist_wrapped = (old != NULL && old->base.grid->hsize != 0 &&
		    (grid_get_line(old->base.grid, old->base.grid->hsize - 1)->flags &
		    GRID_LINE_WRAPPED));
		tty->hist_pane = wp->id;
		tty->hist_seen = gd->scroll_view;
		tty->hist_gen = gd->scroll_generation;
		tty->hist_shown = UINT_MAX;
		return;
	}
	if (tty->hist_gen == gd->scroll_generation)
		return;
	tty->hist_shown = UINT_MAX;
	if (tty->hist_gen + 1 == gd->scroll_generation &&
	    gd->reflow_gen == gd->scroll_generation &&
	    (int)(gd->reflow_view - tty->hist_seen) > 0) {
		m = gd->reflow_view - tty->hist_seen;
		b = (m <= gd->reflow_hsize) ? gd->reflow_hsize - m : 0;
		if (m <= gd->reflow_hsize && b >= gd->reflow_first &&
		    gd->reflow_map != NULL) {
			/*
			 * Its last row was where the cursor was, which the
			 * pane may have written since: one row of its own,
			 * and not known to be the pane's (painted, not only
			 * scrolled).
			 */
			end = gd->reflow_map[b + gd->reflow_osy - 1 -
			    gd->reflow_first] + 1;
			top = (end > tty->sy) ? end - tty->sy : 0;
			log_debug("%s: %u lines behind, end %u top %u",
			    __func__, m, end, top);
			if (top < gd->reflow_newh) {
				tty->hist_seen = gd->reflow_view -
				    (gd->reflow_newh - top);
				tty->hist_shown = end - 1;
			} else
				tty->hist_seen = gd->reflow_view;
		} else
			tty->hist_seen = gd->scroll_view;
	} else if (tty->hist_gen + 1 != gd->scroll_generation ||
	    gd->reflow_gen != gd->scroll_generation)
		tty->hist_seen = gd->scroll_view;
	tty->hist_gen = gd->scroll_generation;
}

/*
 * A pane's scroll or clear, which pushed ctx->n lines into its history, is
 * about to be written to this terminal: count them as reaching the terminal
 * (see tty_catch_up_history), which does with them what it does - keeps them
 * in its scrollback or not. Not when the output is being thrown away
 * (TTY_BLOCK) or the terminal is on its alternate screen.
 */
static void
tty_count_history(struct tty *tty, const struct tty_ctx *ctx)
{
	struct window_pane	*wp = ctx->wp;
	struct grid		*gd;

	if (wp == NULL || ctx->s != &wp->base || SCREEN_IS_ALTERNATE(&wp->base))
		return;
	gd = wp->base.grid;
	if (tty->flags & (TTY_BLOCK|TTY_ALTSCREEN))
		return;
	if (tty->hist_pane != wp->id) {
		tty_follow_history(tty, wp);
		return;
	}
	tty_follow_history(tty, wp);
	tty->hist_seen += ctx->n;
	if ((int)(gd->scroll_view - tty->hist_seen) < 0)
		tty->hist_seen = gd->scroll_view;
}

/* Catch up on a pane's history, from screen_write_flush_dirty. */
void
tty_cmd_history(struct tty *tty, const struct tty_ctx *ctx)
{
	struct window_pane	*wp = ctx->wp;
	int			 ours;

	ours = (wp != NULL && tty->hist_pane == wp->id);
	tty_catch_up_history(tty, wp);
	tty_forget_wraps(tty, wp, ours);	/* every row is drawn next */
}

/*
 * Paint history lines first to last from row y down, a line that wrapped as
 * one so the terminal wraps it itself and keeps it one line.
 *
 * Which rows the terminal joins is what matters here. Erasing a whole row
 * tells some terminals (tmux) it no longer continues the row above, and
 * that the row above no longer continues into it, so: a row that does not
 * continue the line before is erased whole first, which also ends whatever
 * the row above had wrapped into it before; a row that does - the rest of a
 * wrapped line, or the top row continuing the last line in the terminal's
 * scrollback - is only written over. After the text, only the rest of the
 * row is erased; a row wrapping on, or full, is written to its end, spaces
 * too (an erase at the end of a full row would take its last cell on some,
 * such as xterm). And the row after the last is erased whole, unless the
 * last line wraps on to it.
 */
static void
tty_paint_history(struct tty *tty, struct window_pane *wp, u_int first,
    u_int last, u_int y)
{
	struct grid		*gd = wp->base.grid;
	struct grid_line	*gl;
	struct grid_cell	 gc, defaults;
	struct tty_style_ctx	 style_ctx;
	u_int			 k, row, x;
	int			 full, cont;

	/* The pane's own style, palette and links, as when it is drawn. */
	tty_default_colours(&defaults, wp, &style_ctx.dim);
	style_ctx.defaults = &defaults;
	style_ctx.palette = &wp->palette;
	style_ctx.hyperlinks = wp->base.hyperlinks;

	tty_reset(tty);
	for (k = first; k <= last; k++) {
		row = y + k - first;
		gl = grid_get_line(gd, k);
		if (k != first)
			cont = (grid_get_line(gd, k - 1)->flags & GRID_LINE_WRAPPED);
		else {
			cont = (row == 0 && k != 0 &&
			    (grid_get_line(gd, k - 1)->flags & GRID_LINE_WRAPPED));
		}
		if (!cont) {
			tty_default_attributes(tty, 8, &style_ctx);
			tty_cursor(tty, 0, row);
			tty_putcode(tty, TTYC_EL);
		} else if (k == first)
			tty_cursor(tty, 0, row);

		full = ((gl->flags & GRID_LINE_WRAPPED) || gl->cellused >= gd->sx);
		for (x = 0; x < gd->sx && (full || x < gl->cellused); x++) {
			grid_get_cell(gd, x, k, &gc);
			if (gc.flags & GRID_FLAG_PADDING)
				continue;
			tty_cell(tty, &gc, &style_ctx);
		}
		if (!full) {
			tty_default_attributes(tty, 8, &style_ctx);
			tty_putcode(tty, TTYC_EL);
		}
	}
	gl = grid_get_line(gd, last);
	row = y + last - first + 1;
	if ((~gl->flags & GRID_LINE_WRAPPED) && row < tty->sy) {
		tty_default_attributes(tty, 8, &style_ctx);
		tty_cursor(tty, 0, row);
		tty_putcode(tty, TTYC_EL);
	}
	tty_reset(tty);
	tty->cx = tty->cy = UINT_MAX;
}

/* The last line of the wrapped line at i, before end and within n rows. */
static u_int
tty_history_wrapped(struct grid *gd, u_int i, u_int end, u_int n)
{
	u_int	j;

	for (j = i; j + 1 < end && j - i + 1 < n; j++) {
		if (~grid_get_line(gd, j)->flags & GRID_LINE_WRAPPED)
			break;
	}
	return (j);
}

/*
 * Give the terminal history lines i to i + n - 1 as they went into the
 * pane's history (a grid_push): painted where they were and scrolled off a
 * region or the screen, or cleared, so the terminal keeps them in its
 * scrollback exactly when it would have.
 */
static void
tty_replay_push(struct tty *tty, struct window_pane *wp, u_int type,
    u_int upper, u_int lower, u_int i, u_int n)
{
	struct grid	*gd = wp->base.grid;
	u_int		 j, k, m, end = i + n;

	if ((type == GRID_PUSH_CLEAR || type == GRID_PUSH_CLEARBELOW) &&
	    (n > tty->sy || !tty_term_has(tty->term, TTYC_ED)))
		type = GRID_PUSH_SCROLL;
	if (type == GRID_PUSH_REGION &&
	    (lower >= tty->sy || upper >= lower ||
	    !tty_term_has(tty->term, TTYC_CSR)))
		type = GRID_PUSH_SCROLL;

	switch (type) {
	case GRID_PUSH_SCROLL:
		for (k = i; k < end; k = j + 1) {
			j = tty_history_wrapped(gd, k, end, tty->sy - 1);
			tty_region_off(tty);
			tty_paint_history(tty, wp, k, j, 0);
			/*
			 * The line goes on in the next row (the next line
			 * painted, or the top of the screen): wrap into it
			 * with a blank the next write covers, so the terminal
			 * joins them.
			 */
			if (grid_get_line(gd, j)->flags & GRID_LINE_WRAPPED)
				tty_puts(tty, " ");
			tty_cursor(tty, 0, tty->sy - 1);
			for (m = k; m <= j; m++)
				tty_putc(tty, '\n');
		}
		break;
	case GRID_PUSH_REGION:
		for (k = i; k < end; k++) {
			tty_region_off(tty);
			tty_paint_history(tty, wp, k, k, upper);
			tty_region(tty, upper, lower);
			tty_cursor(tty, 0, lower);
			tty_putc(tty, '\n');
		}
		tty_region_off(tty);
		break;
	case GRID_PUSH_CLEAR:
	case GRID_PUSH_CLEARBELOW:
		tty_region_off(tty);
		for (k = i; k < end; k = j + 1) {
			j = tty_history_wrapped(gd, k, end, tty->sy - (k - i));
			tty_paint_history(tty, wp, k, j, k - i);
		}
		if (n < tty->sy) {
			tty_cursor(tty, 0, n);
			tty_putcode(tty, TTYC_ED);
		}
		if (type == GRID_PUSH_CLEAR &&
		    (tty->term->flags & TERM_VT100LIKE))
			tty_puts(tty, "\033[2J");
		else {
			tty_cursor(tty, 0, 0);
			tty_putcode(tty, TTYC_ED);
		}
		break;
	}
}

/*
 * Whether a floating pane is over a pane: drawn over rows that painting it
 * whole, erasing or scrolling it, would take away.
 */
int
tty_pane_covered(struct window_pane *wp)
{
	struct window_pane	*loop = wp;

	while ((loop = TAILQ_PREV(loop, window_panes, zentry)) != NULL) {
		if (window_pane_is_floating(loop))
			return (1);
	}
	return (0);
}

/*
 * Whether a pane is the whole of this terminal, which keeps its own scrollback
 * (clear-on-attach off): where the pane's rows scroll is where the terminal's
 * scroll.
 */
int
tty_pane_is_terminal(struct tty *tty, struct window_pane *wp)
{
	if (wp == NULL || !screen_write_passthrough(wp))
		return (0);
	return (wp->xoff == 0 && wp->yoff == 0 && wp->sx == tty->sx &&
	    wp->sy == tty->sy);
}

/*
 * Write history lines first to first + n - 1 of a pane that is the whole
 * terminal to the terminal's scrollback, as they went into the history when
 * the pane scrolled. The caller redraws the pane over the rows this leaves.
 */
void
tty_replay_history(struct tty *tty, struct window_pane *wp, u_int first,
    u_int n)
{
	if (n == 0)
		return;
	tty_region_off(tty);
	tty_margin_off(tty);
	tty_replay_push(tty, wp, GRID_PUSH_SCROLL, 0, 0, first, n);
}

/*
 * Lines pushed into a pane's history without reaching this terminal - thrown
 * away while the output was held back (sync mode, a full redraw pending, a
 * client too far behind) - are given to it now the way they went into the
 * history (see tty_replay_push); lines older than the grid's record of
 * pushes as full-screen scrolls. The caller redraws the whole pane over the
 * rows this leaves. A pane this terminal was not following, it starts
 * following from here. Only for a pane that is the whole
 * terminal, on the primary screen.
 */
void
tty_catch_up_history(struct tty *tty, struct window_pane *wp)
{
	struct grid		*gd;
	struct grid_push	*gp;
	u_int			 i, j, k, n, left, e, skip = 0, count;

	if (wp == NULL || SCREEN_IS_ALTERNATE(&wp->base))
		return;
	if (tty->flags & (TTY_ALTSCREEN|TTY_BLOCK))
		return;
	gd = wp->base.grid;
	/*
	 * The painting would scroll a floating pane over this one away: wait
	 * for the redraw after it has gone - and keep following the pane the
	 * terminal's scrollback belongs to until then (tty_forget_wraps).
	 */
	if (tty_pane_covered(wp))
		return;
	/*
	 * A floating pane sits over the pane the terminal's scrollback belongs
	 * to; it does not take the scrollback over.
	 */
	if (window_pane_is_floating(wp))
		return;
	if (tty->hist_pane != wp->id) {
		tty_follow_history(tty, wp);
		return;
	}
	tty_follow_history(tty, wp);
	n = gd->scroll_view - tty->hist_seen;
	if ((int)n <= 0)
		return;
	tty->hist_seen = gd->scroll_view;
	if (!tty_pane_is_terminal(tty, wp))
		return;
	if (n > gd->hsize)
		n = gd->hsize;
	log_debug("%s: %%%u %u lines", __func__, wp->id, n);

	/*
	 * History rows the terminal has at the top of its screen after it
	 * reflowed (see tty_follow_history): scroll them into its scrollback.
	 */
	tty_margin_off(tty);
	i = gd->hsize - n;
	if (tty->hist_shown != UINT_MAX && i < tty->hist_shown) {
		k = ((tty->hist_shown < gd->hsize) ? tty->hist_shown :
		    gd->hsize) - i;
		log_debug("%s: %u lines on the screen", __func__, k);
		tty_region_off(tty);
		tty_cursor(tty, 0, tty->sy - 1);
		for (j = 0; j < k; j++)
			tty_putc(tty, '\n');
		n -= k;
	}
	tty->hist_shown = UINT_MAX;

	/* The latest pushes, back to the first of the n lines. */
	left = n;
	e = gd->npushes;
	while (left != 0 && e != 0 && gd->npushes - e < GRID_PUSHES) {
		gp = &gd->pushes[(e - 1) % GRID_PUSHES];
		e--;
		if (gp->n >= left) {
			skip = gp->n - left;
			left = 0;
			break;
		}
		left -= gp->n;
	}

	i = gd->hsize - n;
	if (left != 0) {
		tty_replay_push(tty, wp, GRID_PUSH_SCROLL, 0, 0, i, left);
		i += left;
	}
	for (; e != gd->npushes; e++) {
		gp = &gd->pushes[e % GRID_PUSHES];
		count = gp->n - skip;
		skip = 0;
		log_debug("%s: %u lines, push %u %u-%u", __func__, count,
		    gp->type, gp->upper, gp->lower);
		tty_replay_push(tty, wp, gp->type, gp->upper, gp->lower, i,
		    count);
		i += count;
	}
}

/*
 * Before the whole of a pane that is the whole terminal is drawn again: which
 * of the terminal's rows continue the row above is what earlier output left
 * (perhaps output since thrown away), and drawing over the rows does not
 * change it. Clear them first, so the terminal joins only the rows the drawing
 * wraps - except the top row when it continues the last line of the history,
 * which is in the terminal's scrollback and is not drawn again, if that is
 * this pane's history (ours). Not under a floating pane.
 */
void
tty_forget_wraps(struct tty *tty, struct window_pane *wp, int ours)
{
	struct grid	*gd;

	if (wp == NULL || SCREEN_IS_ALTERNATE(&wp->base))
		return;
	if (tty->flags & (TTY_ALTSCREEN|TTY_BLOCK))
		return;
	if (!tty_pane_is_terminal(tty, wp) || !tty_term_has(tty->term, TTYC_ED))
		return;
	gd = wp->base.grid;

	if (tty_pane_covered(wp))
		return;

	tty_region_off(tty);
	tty_margin_off(tty);
	tty_reset(tty);
	/*
	 * Another pane's line ends the terminal's scrollback and wraps on to
	 * the top row. Most terminals keep that wrap when the row is only
	 * erased, which would join the line to what is drawn there next: erase
	 * the row and scroll it in after the line instead, so the line ends on
	 * a blank row.
	 */
	if (!ours && tty->hist_wrapped && tty->sy > 1) {
		tty_cursor(tty, 0, 0);
		tty_putcode(tty, TTYC_EL);
		tty_cursor(tty, 0, tty->sy - 1);
		tty_putc(tty, '\n');
	}
	tty->hist_wrapped = 0;
	if (!ours || gd->hsize == 0 ||
	    (~grid_get_line(gd, gd->hsize - 1)->flags & GRID_LINE_WRAPPED)) {
		tty_cursor(tty, 0, 0);
		tty_putcode(tty, TTYC_EL);
	}
	if (tty->sy > 1) {
		tty_cursor(tty, 0, 1);
		tty_putcode(tty, TTYC_ED);
	}
}

/*
 * Emit a scroll tty_cmd_scrollup left to a wrap that has not happened: the
 * terminal is waiting to wrap at the end of the bottom row. Something other
 * than a character is written to the new row first (an erase, a cursor
 * move), so wrap with a blank - the row scrolls in blank - and return to its
 * start: the terminal still knows the row continues the one above, as the
 * program's own wrap told it. A wide character that did not fit left the
 * cursor on the last column instead, where a blank would not wrap; a newline
 * scrolls then.
 */
static void
tty_pay_scroll(struct tty *tty)
{
	if (~tty->flags & TTY_OWESCROLL)
		return;
	tty->flags &= ~(TTY_OWESCROLL|TTY_WRAPNEXT);
	log_debug("%s: at %u", __func__, tty->cy);
	tty_reset(tty);
	if (tty->cx >= tty->sx) {
		tty_add(tty, " \r", 2);
		tty->flags |= TTY_WRAPPED0;
	} else
		tty_add(tty, "\r\n", 2);
	tty->cx = 0;
}

/* Move cursor to absolute position. */
/*
 * Whether tty_cursor moves relative to the cursor: the terminal keeps its own
 * scrollback (clear-on-attach off), the cursor position is known, and the
 * scroll region and margins are the whole screen.
 */
static int
tty_move_relative(struct tty *tty, u_int thisy)
{
	struct tty_term	*term = tty->term;

	if (options_get_number(global_options, "clear-on-attach"))
		return (0);
	if (thisy == UINT_MAX || tty->cx == UINT_MAX)
		return (0);
	if (tty->rupper != 0 || tty->rlower != tty->sy - 1)
		return (0);
	if (tty_use_margin(tty) &&
	    (tty->rleft != 0 || tty->rright != tty->sx - 1))
		return (0);
	return (tty_term_has(term, TTYC_CUU) && tty_term_has(term, TTYC_HPA));
}

void
tty_cursor(struct tty *tty, u_int cx, u_int cy)
{
	struct tty_term	*term = tty->term;
	u_int		 thisx, thisy;
	int		 change;

	if (tty->flags & TTY_BLOCK)
		return;
	tty_pay_scroll(tty);
	if (cx != tty->cx || cy != tty->cy)
		tty->flags &= ~TTY_WRAPPED0;

	thisx = tty->cx;
	thisy = tty->cy;

	/*
	 * If in the automargin space, and want to be there, do not move.
	 * Otherwise, force the cursor to be in range (and complain).
	 */
	if (cx == thisx && cy == thisy && cx == tty->sx)
		return;
	if (cx > tty->sx - 1) {
		log_debug("%s: x too big %u > %u", __func__, cx, tty->sx - 1);
		cx = tty->sx - 1;
	}

	/* No change. */
	if (cx == thisx && cy == thisy)
		return;

	/*
	 * Currently at the very end of the line, so a wrap is pending. Moving
	 * relative to the cursor (see tty_move_relative) starts from column 0
	 * after a CR, which also clears the pending wrap; otherwise use
	 * absolute movement.
	 */
	if (thisx > tty->sx - 1) {
		if (!tty_move_relative(tty, thisy))
			goto absolute;
		tty_putc(tty, '\r');
		thisx = tty->cx = 0;
		if (cx == 0 && cy == thisy)
			goto out;
	}

	/*
	 * With clear-on-attach off the terminal keeps its own scrollback and
	 * can move its screen against it without tmux knowing: a phone
	 * keyboard that grows and shrinks the terminal faster than the new
	 * size is reported pulls rows back from scrollback and moves the
	 * cursor down with them. An application drawing straight to the
	 * terminal moves relative to the cursor and stays in line; absolute
	 * movement would draw over the wrong rows. So move relative to the
	 * cursor too, down by line feeds (which scroll such a terminal back
	 * into line rather than stopping at its last row).
	 */
	if (tty_move_relative(tty, thisy)) {
		if (cy < thisy) {
			if (thisy - cy == 1 && tty_term_has(term, TTYC_CUU1))
				tty_putcode(tty, TTYC_CUU1);
			else
				tty_putcode_i(tty, TTYC_CUU, thisy - cy);
		} else {
			for (; thisy < cy; thisy++)
				tty_putc(tty, '\n');
		}
		if (cx == thisx)
			goto out;
		thisy = cy;
		tty->cy = cy;
		if (cx == 0) {
			tty_putc(tty, '\r');
			goto out;
		}
		change = thisx - cx;
		if ((u_int)abs(change) > cx || !tty_term_has(term, TTYC_CUB) ||
		    !tty_term_has(term, TTYC_CUF))
			tty_putcode_i(tty, TTYC_HPA, cx);
		else if (change > 0)
			tty_putcode_i(tty, TTYC_CUB, change);
		else
			tty_putcode_i(tty, TTYC_CUF, -change);
		goto out;
	}

	/* Move to home position (0, 0). */
	if (cx == 0 && cy == 0 && tty_term_has(term, TTYC_HOME)) {
		tty_putcode(tty, TTYC_HOME);
		goto out;
	}

	/* Zero on the next line. */
	if (cx == 0 && cy == thisy + 1 && thisy != tty->rlower &&
	    (!tty_use_margin(tty) || tty->rleft == 0)) {
		tty_putc(tty, '\r');
		tty_putc(tty, '\n');
		goto out;
	}

	/* Moving column or row. */
	if (cy == thisy) {
		/*
		 * Moving column only, row staying the same.
		 */

		/* To left edge. */
		if (cx == 0 && (!tty_use_margin(tty) || tty->rleft == 0)) {
			tty_putc(tty, '\r');
			goto out;
		}

		/* One to the left. */
		if (cx == thisx - 1 && tty_term_has(term, TTYC_CUB1)) {
			tty_putcode(tty, TTYC_CUB1);
			goto out;
		}

		/* One to the right. */
		if (cx == thisx + 1 && tty_term_has(term, TTYC_CUF1)) {
			tty_putcode(tty, TTYC_CUF1);
			goto out;
		}

		/* Calculate difference. */
		change = thisx - cx;	/* +ve left, -ve right */

		/*
		 * Use HPA if change is larger than absolute, otherwise move
		 * the cursor with CUB/CUF.
		 */
		if ((u_int) abs(change) > cx && tty_term_has(term, TTYC_HPA)) {
			tty_putcode_i(tty, TTYC_HPA, cx);
			goto out;
		} else if (change > 0 &&
		    tty_term_has(term, TTYC_CUB) &&
		    !tty_use_margin(tty)) {
			if (change == 2 && tty_term_has(term, TTYC_CUB1)) {
				tty_putcode(tty, TTYC_CUB1);
				tty_putcode(tty, TTYC_CUB1);
				goto out;
			}
			tty_putcode_i(tty, TTYC_CUB, change);
			goto out;
		} else if (change < 0 &&
		    tty_term_has(term, TTYC_CUF) &&
		    !tty_use_margin(tty)) {
			tty_putcode_i(tty, TTYC_CUF, -change);
			goto out;
		}
	} else if (cx == thisx) {
		/*
		 * Moving row only, column staying the same.
		 */

		/* One above. */
		if (thisy != tty->rupper &&
		    cy == thisy - 1 && tty_term_has(term, TTYC_CUU1)) {
			tty_putcode(tty, TTYC_CUU1);
			goto out;
		}

		/* One below. */
		if (thisy != tty->rlower &&
		    cy == thisy + 1 && tty_term_has(term, TTYC_CUD1)) {
			tty_putcode(tty, TTYC_CUD1);
			goto out;
		}

		/* Calculate difference. */
		change = thisy - cy;	/* +ve up, -ve down */

		/*
		 * Try to use VPA if change is larger than absolute or if this
		 * change would cross the scroll region, otherwise use CUU/CUD.
		 */
		if ((u_int) abs(change) > cy ||
		    (change < 0 && cy - change > tty->rlower) ||
		    (change > 0 && cy - change < tty->rupper)) {
			    if (tty_term_has(term, TTYC_VPA)) {
				    tty_putcode_i(tty, TTYC_VPA, cy);
				    goto out;
			    }
		} else if (change > 0 && tty_term_has(term, TTYC_CUU)) {
			tty_putcode_i(tty, TTYC_CUU, change);
			goto out;
		} else if (change < 0 && tty_term_has(term, TTYC_CUD)) {
			tty_putcode_i(tty, TTYC_CUD, -change);
			goto out;
		}
	}

absolute:
	/* Absolute movement. */
	tty_putcode_ii(tty, TTYC_CUP, cy, cx);

out:
	tty->cx = cx;
	tty->cy = cy;
}

static void
tty_hyperlink(struct tty *tty, const struct grid_cell *gc,
    struct hyperlinks *hl)
{
	const char	*uri, *id;

	if (gc->link == tty->cell.link)
		return;
	tty->cell.link = gc->link;

	if (hl == NULL)
		return;

	if (gc->link == 0 || !hyperlinks_get(hl, gc->link, &uri, NULL, &id))
		tty_putcode_ss(tty, TTYC_HLS, "", "");
	else
		tty_putcode_ss(tty, TTYC_HLS, id, uri);
}

static int
tty_dim_default_colour(struct tty *tty, int c, int foreground)
{
	enum client_theme	 theme;

	if (!COLOUR_DEFAULT(c))
		return (c);

	if (foreground && tty->fg != -1)
		return (tty->fg);
	if (!foreground && tty->bg != -1)
		return (tty->bg);

	theme = tty->client->theme;
	if (theme == THEME_DARK)
		return (foreground ? 7 : 0);
	if (theme == THEME_LIGHT)
		return (foreground ? 0 : 7);
	return (c);
}

void
tty_attributes(struct tty *tty, const struct grid_cell *gc,
    const struct tty_style_ctx *style_ctx)
{
	struct grid_cell	*tc = &tty->cell, gc2;
	struct colour_palette	*palette;
	int			 changed;

	/*
	 * A scroll left to a wrap is paid before attributes are set for what
	 * follows, which paying would reset - unless what follows is the
	 * character that wraps.
	 */
	if ((tty->flags & (TTY_OWESCROLL|TTY_WRAPNEXT)) == TTY_OWESCROLL)
		tty_pay_scroll(tty);

	/* Use default style if not given. */
	if (style_ctx == NULL)
		style_ctx = &tty_default_style_ctx;
	palette = style_ctx->palette;

	/* Copy cell and update default colours. */
	memcpy(&gc2, gc, sizeof gc2);
	if (~gc->flags & GRID_FLAG_NOPALETTE) {
		if (gc2.fg == 8)
			gc2.fg = style_ctx->defaults->fg;
		if (gc2.bg == 8)
			gc2.bg = style_ctx->defaults->bg;
		if (palette != NULL) {
			changed = colour_palette_get(palette, gc2.fg);
			if (changed != -1)
				gc2.fg = changed;
			changed = colour_palette_get(palette, gc2.bg);
			if (changed != -1)
				gc2.bg = changed;
		}
	}
	gc2.fg = tty_map_theme_colour(tty, gc2.fg);
	gc2.bg = tty_map_theme_colour(tty, gc2.bg);
	gc2.us = tty_map_theme_colour(tty, gc2.us);
	if (style_ctx->dim != 0) {
		gc2.fg = tty_dim_default_colour(tty, gc2.fg, 1);
		gc2.bg = tty_dim_default_colour(tty, gc2.bg, 0);
		changed = colour_dim(gc2.fg, style_ctx->dim);
		if (changed != -1)
			gc2.fg = changed;
		changed = colour_dim(gc2.bg, style_ctx->dim);
		if (changed != -1)
			gc2.bg = changed;
	}

	/* Ignore cell if it is the same as the last one. */
	if (gc2.attr == tty->last_cell.attr &&
	    gc2.fg == tty->last_cell.fg &&
	    gc2.bg == tty->last_cell.bg &&
	    gc2.us == tty->last_cell.us &&
		gc2.link == tty->last_cell.link)
		return;

	/*
	 * If no setab, try to use the reverse attribute as a best-effort for a
	 * non-default background. This is a bit of a hack but it doesn't do
	 * any serious harm and makes a couple of applications happier.
	 */
	if (!tty_term_has(tty->term, TTYC_SETAB)) {
		if (gc2.attr & GRID_ATTR_REVERSE) {
			if (gc2.fg != 7 && !COLOUR_DEFAULT(gc2.fg))
				gc2.attr &= ~GRID_ATTR_REVERSE;
		} else {
			if (gc2.bg != 0 && !COLOUR_DEFAULT(gc2.bg))
				gc2.attr |= GRID_ATTR_REVERSE;
		}
	}

	/* Fix up the colours if necessary. */
	tty_check_fg(tty, palette, &gc2);
	tty_check_bg(tty, palette, &gc2);
	tty_check_us(tty, palette, &gc2);

	/*
	 * If any bits are being cleared or the underline colour is now default,
	 * reset everything.
	 */
	if ((tc->attr & ~gc2.attr) || (tc->us != gc2.us && gc2.us == 0))
		tty_reset(tty);

	/*
	 * Set the colours. This may call tty_reset() (so it comes next) and
	 * may add to (NOT remove) the desired attributes.
	 */
	tty_colours(tty, &gc2);

	/* Filter out attribute bits already set. */
	changed = gc2.attr & ~tc->attr;
	tc->attr = gc2.attr;

	/* Set the attributes. */
	if (changed & GRID_ATTR_BRIGHT)
		tty_putcode(tty, TTYC_BOLD);
	if (changed & GRID_ATTR_DIM)
		tty_putcode(tty, TTYC_DIM);
	if (changed & GRID_ATTR_ITALICS)
		tty_set_italics(tty);
	if (changed & GRID_ATTR_ALL_UNDERSCORE) {
		/*
		 * A terminal without styled underlines still gets an
		 * underline, rather than none at all.
		 */
		if ((changed & GRID_ATTR_UNDERSCORE) ||
		    !tty_term_has(tty->term, TTYC_SMULX))
			tty_putcode(tty, TTYC_SMUL);
		else if (changed & GRID_ATTR_UNDERSCORE_2)
			tty_putcode_i(tty, TTYC_SMULX, 2);
		else if (changed & GRID_ATTR_UNDERSCORE_3)
			tty_putcode_i(tty, TTYC_SMULX, 3);
		else if (changed & GRID_ATTR_UNDERSCORE_4)
			tty_putcode_i(tty, TTYC_SMULX, 4);
		else if (changed & GRID_ATTR_UNDERSCORE_5)
			tty_putcode_i(tty, TTYC_SMULX, 5);
	}
	if (changed & GRID_ATTR_BLINK)
		tty_putcode(tty, TTYC_BLINK);
	if (changed & GRID_ATTR_REVERSE) {
		if (tty_term_has(tty->term, TTYC_REV))
			tty_putcode(tty, TTYC_REV);
		else if (tty_term_has(tty->term, TTYC_SMSO))
			tty_putcode(tty, TTYC_SMSO);
	}
	if (changed & GRID_ATTR_HIDDEN)
		tty_putcode(tty, TTYC_INVIS);
	if (changed & GRID_ATTR_STRIKETHROUGH)
		tty_putcode(tty, TTYC_SMXX);
	if (changed & GRID_ATTR_OVERLINE)
		tty_putcode(tty, TTYC_SMOL);
	if ((changed & GRID_ATTR_CHARSET) && tty_acs_needed(tty))
		tty_putcode(tty, TTYC_SMACS);

	/* Set hyperlink if any. */
	tty_hyperlink(tty, gc, style_ctx->hyperlinks);

	memcpy(&tty->last_cell, &gc2, sizeof tty->last_cell);
}

static void
tty_colours(struct tty *tty, const struct grid_cell *gc)
{
	struct grid_cell	*tc = &tty->cell;

	/* No changes? Nothing is necessary. */
	if (gc->fg == tc->fg && gc->bg == tc->bg && gc->us == tc->us)
		return;

	/*
	 * Is either the default colour? This is handled specially because the
	 * best solution might be to reset both colours to default, in which
	 * case if only one is default need to fall onward to set the other
	 * colour.
	 */
	if (COLOUR_DEFAULT(gc->fg) || COLOUR_DEFAULT(gc->bg)) {
		/*
		 * If don't have AX, send sgr0. This resets both colours to
		 * default. Otherwise, try to set the default colour only as
		 * needed.
		 */
		if (!tty_term_flag(tty->term, TTYC_AX))
			tty_reset(tty);
		else {
			if (COLOUR_DEFAULT(gc->fg) && !COLOUR_DEFAULT(tc->fg)) {
				tty_puts(tty, "\033[39m");
				tc->fg = gc->fg;
			}
			if (COLOUR_DEFAULT(gc->bg) && !COLOUR_DEFAULT(tc->bg)) {
				tty_puts(tty, "\033[49m");
				tc->bg = gc->bg;
			}
		}
	}

	/* Set the foreground colour. */
	if (!COLOUR_DEFAULT(gc->fg) && gc->fg != tc->fg)
		tty_colours_fg(tty, gc);

	/*
	 * Set the background colour. This must come after the foreground as
	 * tty_colours_fg() can call tty_reset().
	 */
	if (!COLOUR_DEFAULT(gc->bg) && gc->bg != tc->bg)
		tty_colours_bg(tty, gc);

	/* Set the underscore colour. */
	if (gc->us != tc->us)
		tty_colours_us(tty, gc);
}

static int
tty_map_theme_colour(struct tty *tty, int colour)
{
	struct client	*c;
	u_int		 n;
	int		 m;

	if (~colour & COLOUR_FLAG_THEME)
		return (colour);

	n = colour & 0xff;
	if (n >= COLOUR_THEME_COUNT)
		return (8);
	if (tty == NULL || (c = tty->client) == NULL)
		return (8);

	m = c->theme_colours[n];
	if (m == -1 || (m & COLOUR_FLAG_THEME))
		return (8);
	return (m);
}

static void
tty_check_fg(struct tty *tty, struct colour_palette *palette,
    struct grid_cell *gc)
{
	u_char	r, g, b;
	u_int	colours;
	int	c;

	/*
	 * Perform substitution if this pane has a palette. If the bright
	 * attribute is set and Nobr is not present, use the bright entry in
	 * the palette by changing to the aixterm colour
	 */
	if (~gc->flags & GRID_FLAG_NOPALETTE) {
		c = gc->fg;
		if (c < 8 &&
		    gc->attr & GRID_ATTR_BRIGHT &&
		    !tty_term_has(tty->term, TTYC_NOBR))
			c += 90;
		if ((c = colour_palette_get(palette, c)) != -1)
			gc->fg = c;
	}
	gc->fg = tty_map_theme_colour(tty, gc->fg);

	/* Is this a 24-bit colour? */
	if (gc->fg & COLOUR_FLAG_RGB) {
		/* Not a 24-bit terminal? Translate to 256-colour palette. */
		if (tty->term->flags & TERM_RGBCOLOURS)
			return;
		colour_split_rgb(gc->fg, &r, &g, &b);
		gc->fg = colour_find_rgb(r, g, b);
	}

	/* How many colours does this terminal have? */
	if (tty->term->flags & TERM_256COLOURS)
		colours = 256;
	else
		colours = tty_term_number(tty->term, TTYC_COLORS);

	/* Is this a 256-colour colour? */
	if (gc->fg & COLOUR_FLAG_256) {
		/* And not a 256 colour mode? */
		if (colours >= 256)
			return;
		gc->fg = colour_256to16(gc->fg);
		if (~gc->fg & 8)
			return;
		gc->fg &= 7;
		if (colours >= 16)
			gc->fg += 90;
		else {
			/*
			 * Mapping to black-on-black or white-on-white is not
			 * much use, so change the foreground.
			 */
			if (gc->fg == 0 && gc->bg == 0)
				gc->fg = 7;
			else if (gc->fg == 7 && gc->bg == 7)
				gc->fg = 0;
		}
		return;
	}

	/* Is this an aixterm colour? */
	if (gc->fg >= 90 && gc->fg <= 97 && colours < 16) {
		gc->fg -= 90;
		gc->attr |= GRID_ATTR_BRIGHT;
	}
}

static void
tty_check_bg(struct tty *tty, struct colour_palette *palette,
    struct grid_cell *gc)
{
	u_char	r, g, b;
	u_int	colours;
	int	c;

	/* Perform substitution if this pane has a palette. */
	if (~gc->flags & GRID_FLAG_NOPALETTE) {
		if ((c = colour_palette_get(palette, gc->bg)) != -1)
			gc->bg = c;
	}
	gc->bg = tty_map_theme_colour(tty, gc->bg);

	/* Is this a 24-bit colour? */
	if (gc->bg & COLOUR_FLAG_RGB) {
		/* Not a 24-bit terminal? Translate to 256-colour palette. */
		if (tty->term->flags & TERM_RGBCOLOURS)
			return;
		colour_split_rgb(gc->bg, &r, &g, &b);
		gc->bg = colour_find_rgb(r, g, b);
	}

	/* How many colours does this terminal have? */
	if (tty->term->flags & TERM_256COLOURS)
		colours = 256;
	else
		colours = tty_term_number(tty->term, TTYC_COLORS);

	/* Is this a 256-colour colour? */
	if (gc->bg & COLOUR_FLAG_256) {
		/*
		 * And not a 256 colour mode? Translate to 16-colour
		 * palette. Bold background doesn't exist portably, so just
		 * discard the bold bit if set.
		 */
		if (colours >= 256)
			return;
		gc->bg = colour_256to16(gc->bg);
		if (~gc->bg & 8)
			return;
		gc->bg &= 7;
		if (colours >= 16)
			gc->bg += 90;
		return;
	}

	/* Is this an aixterm colour? */
	if (gc->bg >= 90 && gc->bg <= 97 && colours < 16)
		gc->bg -= 90;
}

static void
tty_check_us(__unused struct tty *tty, struct colour_palette *palette,
    struct grid_cell *gc)
{
	int	c;

	/* Perform substitution if this pane has a palette. */
	if (~gc->flags & GRID_FLAG_NOPALETTE) {
		if ((c = colour_palette_get(palette, gc->us)) != -1)
			gc->us = c;
	}
	gc->us = tty_map_theme_colour(tty, gc->us);

	/* Convert underscore colour if only RGB can be supported. */
	if (!tty_term_has(tty->term, TTYC_SETULC1)) {
		    if ((c = colour_force_rgb (gc->us)) == -1)
			    gc->us = 8;
		    else
			    gc->us = c;
	}
}

static void
tty_colours_fg(struct tty *tty, const struct grid_cell *gc)
{
	struct grid_cell	*tc = &tty->cell;
	char			 s[32];

	/*
	 * If the current colour is an aixterm bright colour and the new is not,
	 * reset because some terminals do not clear bright correctly.
	 */
	if (tty->cell.fg >= 90 &&
	    tty->cell.bg <= 97 &&
	    (gc->fg < 90 || gc->fg > 97))
		tty_reset(tty);

	/* Is this a 24-bit or 256-colour colour? */
	if (gc->fg & COLOUR_FLAG_RGB || gc->fg & COLOUR_FLAG_256) {
		if (tty_try_colour(tty, gc->fg, "38") == 0)
			goto save;
		/* Should not get here, already converted in tty_check_fg. */
		return;
	}

	/* Is this an aixterm bright colour? */
	if (gc->fg >= 90 && gc->fg <= 97) {
		if (tty->term->flags & TERM_256COLOURS) {
			xsnprintf(s, sizeof s, "\033[%dm", gc->fg);
			tty_puts(tty, s);
		} else
			tty_putcode_i(tty, TTYC_SETAF, gc->fg - 90 + 8);
		goto save;
	}

	/* Otherwise set the foreground colour. */
	tty_putcode_i(tty, TTYC_SETAF, gc->fg);

save:
	/* Save the new values in the terminal current cell. */
	tc->fg = gc->fg;
}

static void
tty_colours_bg(struct tty *tty, const struct grid_cell *gc)
{
	struct grid_cell	*tc = &tty->cell;
	char			 s[32];

	/* Is this a 24-bit or 256-colour colour? */
	if (gc->bg & COLOUR_FLAG_RGB || gc->bg & COLOUR_FLAG_256) {
		if (tty_try_colour(tty, gc->bg, "48") == 0)
			goto save;
		/* Should not get here, already converted in tty_check_bg. */
		return;
	}

	/* Is this an aixterm bright colour? */
	if (gc->bg >= 90 && gc->bg <= 97) {
		if (tty->term->flags & TERM_256COLOURS) {
			xsnprintf(s, sizeof s, "\033[%dm", gc->bg + 10);
			tty_puts(tty, s);
		} else
			tty_putcode_i(tty, TTYC_SETAB, gc->bg - 90 + 8);
		goto save;
	}

	/* Otherwise set the background colour. */
	tty_putcode_i(tty, TTYC_SETAB, gc->bg);

save:
	/* Save the new values in the terminal current cell. */
	tc->bg = gc->bg;
}

static void
tty_colours_us(struct tty *tty, const struct grid_cell *gc)
{
	struct grid_cell	*tc = &tty->cell;
	u_int			 c;
	u_char			 r, g, b;

	/* Clear underline colour. */
	if (COLOUR_DEFAULT(gc->us)) {
		tty_putcode(tty, TTYC_OL);
		goto save;
	}

	/*
	 * If this is not an RGB colour, use Setulc1 if it exists, otherwise
	 * convert.
	 */
	if (~gc->us & COLOUR_FLAG_RGB) {
		c = gc->us;
		if ((~c & COLOUR_FLAG_256) && (c >= 90 && c <= 97))
			c -= 82;
		tty_putcode_i(tty, TTYC_SETULC1, c & ~COLOUR_FLAG_256);
		return;
	}

	/*
	 * Setulc and setal follows the ncurses(3) one argument "direct colour"
	 * capability format. Calculate the colour value.
	 */
	colour_split_rgb(gc->us, &r, &g, &b);
	c = (65536 * r) + (256 * g) + b;

	/*
	 * Write the colour. Only use setal if the RGB flag is set because the
	 * non-RGB version may be wrong.
	 */
	if (tty_term_has(tty->term, TTYC_SETULC))
		tty_putcode_i(tty, TTYC_SETULC, c);
	else if (tty_term_has(tty->term, TTYC_SETAL) &&
	    tty_term_has(tty->term, TTYC_RGB))
		tty_putcode_i(tty, TTYC_SETAL, c);

save:
	/* Save the new values in the terminal current cell. */
	tc->us = gc->us;
}

static int
tty_try_colour(struct tty *tty, int colour, const char *type)
{
	u_char	r, g, b;

	if (colour & COLOUR_FLAG_256) {
		if (*type == '3' && tty_term_has(tty->term, TTYC_SETAF))
			tty_putcode_i(tty, TTYC_SETAF, colour & 0xff);
		else if (tty_term_has(tty->term, TTYC_SETAB))
			tty_putcode_i(tty, TTYC_SETAB, colour & 0xff);
		return (0);
	}

	if (colour & COLOUR_FLAG_RGB) {
		colour_split_rgb(colour & 0xffffff, &r, &g, &b);
		if (*type == '3' && tty_term_has(tty->term, TTYC_SETRGBF))
			tty_putcode_iii(tty, TTYC_SETRGBF, r, g, b);
		else if (tty_term_has(tty->term, TTYC_SETRGBB))
			tty_putcode_iii(tty, TTYC_SETRGBB, r, g, b);
		return (0);
	}

	return (-1);
}

static void
tty_window_default_style(struct grid_cell *gc, struct window_pane *wp)
{
	memcpy(gc, &grid_default_cell, sizeof *gc);
	gc->fg = wp->palette.fg;
	gc->bg = wp->palette.bg;
}

static void
tty_style_changed(struct window_pane *wp)
{
	struct options		*oo = wp->options;
	struct format_tree	*ft;
	struct style		*sy;

	log_debug("%%%u: style changed", wp->id);
	wp->flags &= ~PANE_STYLECHANGED;

	ft = format_create(NULL, NULL, FORMAT_PANE|wp->id, FORMAT_NOJOBS);
	format_defaults(ft, NULL, NULL, NULL, wp);

	tty_window_default_style(&wp->cached_active_gc, wp);
	sy = style_add(&wp->cached_active_gc, oo, "window-active-style", ft);
	wp->cached_active_dim = sy->dim;

	tty_window_default_style(&wp->cached_gc, wp);
	sy = style_add(&wp->cached_gc, oo, "window-style", ft);
	wp->cached_dim = sy->dim;

	format_free(ft);
}

void
tty_default_colours(struct grid_cell *gc, struct window_pane *wp, u_int *dim)
{
	if (wp->flags & PANE_STYLECHANGED)
		tty_style_changed (wp);

	memcpy(gc, &grid_default_cell, sizeof *gc);
	if (wp == wp->window->active && wp->cached_active_gc.fg != 8)
		gc->fg = wp->cached_active_gc.fg;
	else
		gc->fg = wp->cached_gc.fg;
	if (wp == wp->window->active && wp->cached_active_gc.bg != 8)
		gc->bg = wp->cached_active_gc.bg;
	else
		gc->bg = wp->cached_gc.bg;

	if (dim != NULL) {
		if (wp == wp->window->active)
			*dim = wp->cached_active_dim;
		else
			*dim = wp->cached_dim;
	}
}

void
tty_default_attributes(struct tty *tty, u_int bg,
    const struct tty_style_ctx *style_ctx)
{
	struct grid_cell	gc;

	memcpy(&gc, &grid_default_cell, sizeof gc);
	gc.bg = bg;
	tty_attributes(tty, &gc, style_ctx);
}

static void
tty_clipboard_query_callback(__unused int fd, __unused short events, void *data)
{
	struct tty	*tty = data;

	tty->flags &= ~TTY_OSC52QUERY;
}

void
tty_clipboard_query(struct tty *tty)
{
	struct timeval	 tv = { .tv_sec = TTY_QUERY_TIMEOUT };

	if ((tty->flags & TTY_STARTED) && (~tty->flags & TTY_OSC52QUERY)) {
		tty_putcode_ss(tty, TTYC_MS, "", "?");
		tty->flags |= TTY_OSC52QUERY;
		evtimer_add(&tty->clipboard_timer, &tv);
	}
}

void
tty_set_progress_bar(struct tty *tty, struct progress_bar *pb)
{
	if (tty_term_has(tty->term, TTYC_SPB))
		tty_putcode_ii(tty, TTYC_SPB, pb->state, pb->progress);
}
