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
#include <sys/mman.h>
#include <sys/stat.h>

#include <fcntl.h>
#include <limits.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "tmux.h"

/*
 * The kitty graphics protocol for programs in panes. tmux keeps the images
 * and gives them to each terminal that has the protocol with ids of its own,
 * as virtual placements (U=1). Where a program displays an image, the pane
 * holds Unicode placeholder cells (U+10EEEE with the image id as the
 * foreground colour, the placement id as the underline colour and diacritics
 * for the row and column), which tmux draws like any text, so the image moves
 * with the pane, scrolls with the text and comes back when the pane is drawn
 * again. The terminal draws the image where the placeholders are.
 */

/* Row and column numbers as diacritics, from kitty's rowcolumn-diacritics. */
static const u_int kgfx_diacritics[] = {
	0x305, 0x30d, 0x30e, 0x310, 0x312, 0x33d, 0x33e, 0x33f, 0x346, 0x34a,
	0x34b, 0x34c, 0x350, 0x351, 0x352, 0x357, 0x35b, 0x363, 0x364, 0x365,
	0x366, 0x367, 0x368, 0x369, 0x36a, 0x36b, 0x36c, 0x36d, 0x36e, 0x36f,
	0x483, 0x484, 0x485, 0x486, 0x487, 0x592, 0x593, 0x594, 0x595, 0x597,
	0x598, 0x599, 0x59c, 0x59d, 0x59e, 0x59f, 0x5a0, 0x5a1, 0x5a8, 0x5a9,
	0x5ab, 0x5ac, 0x5af, 0x5c4, 0x610, 0x611, 0x612, 0x613, 0x614, 0x615,
	0x616, 0x617, 0x657, 0x658, 0x659, 0x65a, 0x65b, 0x65d, 0x65e, 0x6d6,
	0x6d7, 0x6d8, 0x6d9, 0x6da, 0x6db, 0x6dc, 0x6df, 0x6e0, 0x6e1, 0x6e2,
	0x6e4, 0x6e7, 0x6e8, 0x6eb, 0x6ec, 0x730, 0x732, 0x733, 0x735, 0x736,
	0x73a, 0x73d, 0x73f, 0x740, 0x741, 0x743, 0x745, 0x747, 0x749, 0x74a,
	0x7eb, 0x7ec, 0x7ed, 0x7ee, 0x7ef, 0x7f0, 0x7f1, 0x7f3, 0x816, 0x817,
	0x818, 0x819, 0x81b, 0x81c, 0x81d, 0x81e, 0x81f, 0x820, 0x821, 0x822,
	0x823, 0x825, 0x826, 0x827, 0x829, 0x82a, 0x82b, 0x82c, 0x82d, 0x951,
	0x953, 0x954, 0xf82, 0xf83, 0xf86, 0xf87, 0x135d, 0x135e, 0x135f,
	0x17dd, 0x193a, 0x1a17, 0x1a75, 0x1a76, 0x1a77, 0x1a78, 0x1a79,
	0x1a7a, 0x1a7b, 0x1a7c, 0x1b6b, 0x1b6d, 0x1b6e, 0x1b6f, 0x1b70,
	0x1b71, 0x1b72, 0x1b73, 0x1cd0, 0x1cd1, 0x1cd2, 0x1cda, 0x1cdb,
	0x1ce0, 0x1dc0, 0x1dc1, 0x1dc3, 0x1dc4, 0x1dc5, 0x1dc6, 0x1dc7,
	0x1dc8, 0x1dc9, 0x1dcb, 0x1dcc, 0x1dd1, 0x1dd2, 0x1dd3, 0x1dd4,
	0x1dd5, 0x1dd6, 0x1dd7, 0x1dd8, 0x1dd9, 0x1dda, 0x1ddb, 0x1ddc,
	0x1ddd, 0x1dde, 0x1ddf, 0x1de0, 0x1de1, 0x1de2, 0x1de3, 0x1de4,
	0x1de5, 0x1de6, 0x1dfe, 0x20d0, 0x20d1, 0x20d4, 0x20d5, 0x20d6,
	0x20d7, 0x20db, 0x20dc, 0x20e1, 0x20e7, 0x20e9, 0x20f0, 0x2cef,
	0x2cf0, 0x2cf1, 0x2de0, 0x2de1, 0x2de2, 0x2de3, 0x2de4, 0x2de5,
	0x2de6, 0x2de7, 0x2de8, 0x2de9, 0x2dea, 0x2deb, 0x2dec, 0x2ded,
	0x2dee, 0x2def, 0x2df0, 0x2df1, 0x2df2, 0x2df3, 0x2df4, 0x2df5,
	0x2df6, 0x2df7, 0x2df8, 0x2df9, 0x2dfa, 0x2dfb, 0x2dfc, 0x2dfd,
	0x2dfe, 0x2dff, 0xa66f, 0xa67c, 0xa67d, 0xa6f0, 0xa6f1, 0xa8e0,
	0xa8e1, 0xa8e2, 0xa8e3, 0xa8e4, 0xa8e5, 0xa8e6, 0xa8e7, 0xa8e8,
	0xa8e9, 0xa8ea, 0xa8eb, 0xa8ec, 0xa8ed, 0xa8ee, 0xa8ef, 0xa8f0,
	0xa8f1, 0xaab0, 0xaab2, 0xaab3, 0xaab7, 0xaab8, 0xaabe, 0xaabf,
	0xaac1, 0xfe20, 0xfe21, 0xfe22, 0xfe23, 0xfe24, 0xfe25, 0xfe26,
	0x10a0f, 0x10a38, 0x1d185, 0x1d186, 0x1d187, 0x1d188, 0x1d189,
	0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad, 0x1d242, 0x1d243, 0x1d244
};
#define KGFX_MAXCELLS nitems(kgfx_diacritics)

/* The largest id tmux gives out: it must fit in an RGB colour. */
#define KGFX_MAXID 0xffffff

/* Base64 characters in each chunk sent to a terminal. */
#define KGFX_CHUNK 4096

/* Most images kept: more and the oldest go. */
#define KGFX_MAXIMAGES 4096

/* Image data kept (to give to terminals that come later), in bytes. */
#define KGFX_QUOTA (256 * 1024 * 1024)

/* Any failure to read a file, as kitty: nothing about why or what is there. */
#define KGFX_FILE_ERROR "EBADF:Failed to read image file"

/* Most keys in a command. */
#define KGFX_MAXKEYS 32

/* A parsed command: keys and values, then the payload. */
struct kgfx_cmd {
	char		 key[KGFX_MAXKEYS];
	char		*value[KGFX_MAXKEYS];
	u_int		 nkeys;
	char		*payload;
};

/* A placement of an image. */
struct kgfx_placement {
	u_int				 id;	  /* the program's, 0 if none */
	u_int				 gpid;	  /* tmux's */
	int				 virtual; /* the program's own U=1 */
	int				 z;
	char				*keys;	  /* for terminals: c=,r=,... */
	TAILQ_ENTRY(kgfx_placement)	 entry;
};

/* An image. */
struct kgfx_image {
	u_int				 gid;	/* tmux's id */
	u_int				 pane;
	u_int				 id;	/* the program's, 0 if none */
	u_int				 number; /* the program's I, 0 if none */
	u_int				 order;
	char				*keys;	/* for terminals: f=,s=,v=,o= */
	char				*data;	/* base64 */
	size_t				 size;
	u_int				 width;	/* pixels, 0 if not known */
	u_int				 height;
	TAILQ_HEAD(, kgfx_placement)	 placements;
	TAILQ_ENTRY(kgfx_image)		 entry;
};
static TAILQ_HEAD(, kgfx_image) kgfx_images =
    TAILQ_HEAD_INITIALIZER(kgfx_images);
static size_t	kgfx_size;
static u_int	kgfx_count;
static u_int	kgfx_next_gid = 1;
static u_int	kgfx_next_gpid = 1;
static u_int	kgfx_order;

/* A chunked transmission being put together. */
struct kgfx_pending {
	u_int				 pane;
	struct kgfx_cmd			*first;
	struct evbuffer			*data;
	TAILQ_ENTRY(kgfx_pending)	 entry;
};
static TAILQ_HEAD(, kgfx_pending) kgfx_pendings =
    TAILQ_HEAD_INITIALIZER(kgfx_pendings);

static void	kgfx_delete_image(struct window_pane *, struct kgfx_image *,
		    int);

/* Free a command. */
static void
kgfx_free_cmd(struct kgfx_cmd *cmd)
{
	u_int	i;

	if (cmd == NULL)
		return;
	for (i = 0; i < cmd->nkeys; i++)
		free(cmd->value[i]);
	free(cmd->payload);
	free(cmd);
}

/* Parse G key=value,...;payload. */
static struct kgfx_cmd *
kgfx_parse(const u_char *buf, size_t len)
{
	struct kgfx_cmd	*cmd;
	size_t		 i = 1, start;

	if (len == 0 || buf[0] != 'G')
		return (NULL);
	cmd = xcalloc(1, sizeof *cmd);
	while (i < len && buf[i] != ';') {
		if (i + 1 >= len || buf[i + 1] != '=' ||
		    cmd->nkeys == KGFX_MAXKEYS)
			goto fail;
		cmd->key[cmd->nkeys] = buf[i];
		start = i + 2;
		for (i = start; i < len && buf[i] != ',' && buf[i] != ';'; i++)
			/* nothing */;
		cmd->value[cmd->nkeys++] = xstrndup(buf + start, i - start);
		if (i < len && buf[i] == ',')
			i++;
	}
	if (i < len && buf[i] == ';')
		cmd->payload = xstrndup(buf + i + 1, len - i - 1);
	else
		cmd->payload = xstrdup("");
	return (cmd);

fail:
	kgfx_free_cmd(cmd);
	return (NULL);
}

/* Get a key's value. */
static const char *
kgfx_get(struct kgfx_cmd *cmd, char key)
{
	u_int	i;

	for (i = 0; i < cmd->nkeys; i++) {
		if (cmd->key[i] == key)
			return (cmd->value[i]);
	}
	return (NULL);
}

/* Get a key's value as a number. */
static u_int
kgfx_number(struct kgfx_cmd *cmd, char key, u_int dflt)
{
	const char	*value = kgfx_get(cmd, key);
	const char	*errstr;
	long long	 n;

	if (value == NULL)
		return (dflt);
	n = strtonum(value, 0, UINT_MAX, &errstr);
	if (errstr != NULL)
		return (dflt);
	return (n);
}

/* Get a key's value as a signed number. */
static int
kgfx_signed(struct kgfx_cmd *cmd, char key, int dflt)
{
	const char	*value = kgfx_get(cmd, key);
	const char	*errstr;
	long long	 n;

	if (value == NULL)
		return (dflt);
	n = strtonum(value, INT_MIN, INT_MAX, &errstr);
	if (errstr != NULL)
		return (dflt);
	return (n);
}

/* Get a key's value as a character. */
static char
kgfx_char(struct kgfx_cmd *cmd, char key, char dflt)
{
	const char	*value = kgfx_get(cmd, key);

	if (value == NULL || value[0] == '\0' || value[1] != '\0')
		return (dflt);
	return (value[0]);
}

/* Copy the keys in keep to a string for terminals: k=v,... */
static char *
kgfx_keys(struct kgfx_cmd *cmd, const char *keep)
{
	struct evbuffer	*b;
	char		*s;
	u_int		 i;

	if ((b = evbuffer_new()) == NULL)
		fatalx("out of memory");
	for (i = 0; i < cmd->nkeys; i++) {
		if (strchr(keep, cmd->key[i]) == NULL)
			continue;
		evbuffer_add_printf(b, ",%c=%s", cmd->key[i], cmd->value[i]);
	}
	evbuffer_add(b, "", 1);
	s = xstrdup(EVBUFFER_DATA(b));
	evbuffer_free(b);
	return (s);
}

/* Whether a client's terminal takes images. */
static int
kgfx_client(struct client *c)
{
	if (c->session == NULL || (~c->tty.flags & TTY_STARTED))
		return (0);
	if (c->flags & (CLIENT_CONTROL|CLIENT_SUSPENDED|CLIENT_EXIT|CLIENT_DEAD))
		return (0);
	return ((c->tty.term->flags & TERM_KGFX) != 0);
}

/*
 * Whether a terminal showing the pane takes images: 1 if one does, -1 if one
 * might (it has not answered yet), 0 if none does.
 */
static int
kgfx_supported(struct window_pane *wp)
{
	struct client	*c;
	int		 maybe = 0;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session == NULL || !session_has(c->session, wp->window))
			continue;
		if (kgfx_client(c))
			return (1);
		if ((c->tty.flags & TTY_STARTED) &&
		    (~c->tty.flags & TTY_HAVEKGFX))
			maybe = 1;
	}
	return (maybe ? -1 : 0);
}

/*
 * A terminal has answered tmux's query, or not answered it: an answer to a
 * program's query waiting for it goes if the terminal has the protocol.
 */
void
kgfx_known(struct client *c)
{
	int	yes = kgfx_client(c);

	input_request_reply(c, INPUT_REQUEST_KGFX, &yes);
}

/* Send a string to one terminal, or every terminal that takes images. */
static void
kgfx_send(struct client *only, const char *s)
{
	struct client	*c;

	if (only != NULL) {
		tty_puts(&only->tty, s);
		return;
	}
	TAILQ_FOREACH(c, &clients, entry) {
		if (kgfx_client(c))
			tty_puts(&c->tty, s);
	}
}

/* Send an image to terminals, in chunks. */
static void
kgfx_send_image(struct client *c, struct kgfx_image *im)
{
	char	*s;
	size_t	 off = 0, n;
	int	 more;

	if (im->data == NULL)
		return;
	do {
		n = im->size - off;
		if (n > KGFX_CHUNK)
			n = KGFX_CHUNK;
		more = (off + n < im->size);
		if (off == 0) {
			xasprintf(&s, "\033_Ga=t,q=2,i=%u%s,m=%d;%.*s\033\\",
			    im->gid, im->keys, more, (int)n, im->data);
		} else {
			xasprintf(&s, "\033_Gm=%d,q=2;%.*s\033\\", more,
			    (int)n, im->data + off);
		}
		kgfx_send(c, s);
		free(s);
		off += n;
	} while (more);
}

/* Send a placement to terminals: always a virtual one. */
static void
kgfx_send_placement(struct client *c, struct kgfx_image *im,
    struct kgfx_placement *pl)
{
	char	*s;

	xasprintf(&s, "\033_Ga=p,U=1,q=2,i=%u,p=%u%s\033\\", im->gid, pl->gpid,
	    pl->keys);
	kgfx_send(c, s);
	free(s);
}

/* Give a terminal that has just been found to take images all of them. */
void
kgfx_replay(struct client *c)
{
	struct kgfx_image	*im;
	struct kgfx_placement	*pl;

	if (!kgfx_client(c))
		return;
	TAILQ_FOREACH(im, &kgfx_images, entry) {
		kgfx_send_image(c, im);
		TAILQ_FOREACH(pl, &im->placements, entry)
			kgfx_send_placement(c, im, pl);
	}
}

/* Reply to the program, unless it asked for no replies of this kind. */
static void
kgfx_reply(struct bufferevent *bev, struct kgfx_cmd *cmd, u_int id,
    u_int number, u_int p, const char *msg)
{
	u_int	 q = kgfx_number(cmd, 'q', 0);
	int	 ok = (strcmp(msg, "OK") == 0);
	char	*s;

	if (bev == NULL || (ok && q >= 1) || (!ok && q >= 2))
		return;
	if (id == 0 && number == 0)
		return;
	if (number != 0 && p != 0)
		xasprintf(&s, "\033_Gi=%u,I=%u,p=%u;%s\033\\", id, number, p, msg);
	else if (number != 0)
		xasprintf(&s, "\033_Gi=%u,I=%u;%s\033\\", id, number, msg);
	else if (p != 0)
		xasprintf(&s, "\033_Gi=%u,p=%u;%s\033\\", id, p, msg);
	else
		xasprintf(&s, "\033_Gi=%u;%s\033\\", id, msg);
	bufferevent_write(bev, s, strlen(s));
	free(s);
}

/*
 * Hold an OK answer to a query until a terminal showing the pane has said
 * whether it has the protocol.
 */
static void
kgfx_hold(struct window_pane *wp, struct kgfx_cmd *cmd, u_int id)
{
	struct client	*c;
	char		*reply;

	if (id == 0 || kgfx_number(cmd, 'q', 0) >= 1)
		return;
	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session == NULL || !session_has(c->session, wp->window))
			continue;
		if ((c->tty.flags & TTY_STARTED) &&
		    (~c->tty.flags & TTY_HAVEKGFX))
			break;
	}
	if (c == NULL)
		return;
	xasprintf(&reply, "\033_Gi=%u;OK\033\\", id);
	input_kgfx_request(wp->ictx, c, reply);
	free(reply);
}

/* A new id, one not in use. */
static u_int
kgfx_new_gid(void)
{
	struct kgfx_image	*im;
	u_int			 gid, tries;

	for (tries = 0; tries < KGFX_MAXID; tries++) {
		gid = kgfx_next_gid++;
		if (kgfx_next_gid > KGFX_MAXID)
			kgfx_next_gid = 1;
		TAILQ_FOREACH(im, &kgfx_images, entry) {
			if (im->gid == gid)
				break;
		}
		if (im == NULL)
			return (gid);
	}
	return (0);
}

/* A new placement id. */
static u_int
kgfx_new_gpid(void)
{
	u_int	gpid = kgfx_next_gpid++;

	if (kgfx_next_gpid > KGFX_MAXID)
		kgfx_next_gpid = 1;
	return (gpid);
}

/* Find a pane's image by the program's id. */
static struct kgfx_image *
kgfx_find(u_int pane, u_int id)
{
	struct kgfx_image	*im;

	if (id == 0)
		return (NULL);
	TAILQ_FOREACH(im, &kgfx_images, entry) {
		if (im->pane == pane && im->id == id)
			return (im);
	}
	return (NULL);
}

/* Find a pane's newest image with a number. */
static struct kgfx_image *
kgfx_find_number(u_int pane, u_int number)
{
	struct kgfx_image	*im, *found = NULL;

	if (number == 0)
		return (NULL);
	TAILQ_FOREACH(im, &kgfx_images, entry) {
		if (im->pane == pane && im->number == number &&
		    (found == NULL || im->order > found->order))
			found = im;
	}
	return (found);
}

/* Keep the stored data within the quota: the oldest images lose theirs. */
static void
kgfx_quota(void)
{
	struct kgfx_image	*im;

	TAILQ_FOREACH(im, &kgfx_images, entry) {
		if (kgfx_size <= KGFX_QUOTA)
			break;
		if (im->data == NULL)
			continue;
		kgfx_size -= im->size;
		free(im->data);
		im->data = NULL;
		im->size = 0;
	}
}

/*
 * Read the data from a file, a temporary file or shared memory (base64 of the
 * name) and make it base64 data, so terminals elsewhere can have it.
 */
static char *
kgfx_read_medium(char t, const char *payload, struct kgfx_cmd *cmd,
    const char **error)
{
	u_char		 name[PATH_MAX], *data = NULL;
	char		*out;
	int		 n, fd = -1;
	size_t		 size, want, off, got;
	struct stat	 sb;
	ssize_t		 r;
	void		*map;

	*error = KGFX_FILE_ERROR;
	n = b64_pton(payload, name, sizeof name - 1);
	if (n <= 0)
		return (NULL);
	name[n] = '\0';

	if (t == 's') {
		*error = KGFX_FILE_ERROR;
		fd = shm_open(name, O_RDONLY, 0);
		if (fd == -1)
			return (NULL);
		if (fstat(fd, &sb) != 0)
			goto fail;
		map = mmap(NULL, sb.st_size, PROT_READ, MAP_SHARED, fd, 0);
		if (map == MAP_FAILED)
			goto fail;
		size = sb.st_size;
		data = xmalloc(size);
		memcpy(data, map, size);
		munmap(map, sb.st_size);
		close(fd);
		shm_unlink(name);
		fd = -1;
	} else {
		/* A temporary file must be one kitty would delete. */
		if (t == 't' && strstr(name, "tty-graphics-protocol") == NULL) {
			*error = KGFX_FILE_ERROR;
			return (NULL);
		}
		*error = KGFX_FILE_ERROR;
		fd = open(name, O_RDONLY);
		if (fd == -1 || fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode))
			goto fail;
		off = kgfx_number(cmd, 'O', 0);
		want = kgfx_number(cmd, 'S', 0);
		if (off > (size_t)sb.st_size)
			goto fail;
		size = sb.st_size - off;
		if (want != 0 && want < size)
			size = want;
		if (lseek(fd, off, SEEK_SET) == -1)
			goto fail;
		data = xmalloc(size ? size : 1);
		for (got = 0; got < size; got += r) {
			r = read(fd, data + got, size - got);
			if (r <= 0)
				goto fail;
		}
		close(fd);
		fd = -1;
		if (t == 't')
			unlink(name);
	}

	out = xmalloc(size * 4 / 3 + 8);
	if (b64_ntop(data, size, out, size * 4 / 3 + 8) == -1) {
		free(out);
		out = NULL;
	}
	free(data);
	return (out);

fail:
	if (fd != -1)
		close(fd);
	free(data);
	return (NULL);
}

/*
 * Check the transmission keys and data (base64) as kitty would: the error to
 * answer with, or NULL.
 */
static const char *
kgfx_check(struct kgfx_cmd *cmd, const char *data)
{
	static char	 error[128];
	u_int		 f = kgfx_number(cmd, 'f', 32);
	u_int		 w = kgfx_number(cmd, 's', 0);
	u_int		 h = kgfx_number(cmd, 'v', 0);
	char		 t = kgfx_char(cmd, 't', 'd');
	char		 o = kgfx_char(cmd, 'o', 0);
	size_t		 len = strlen(data), have, need;

	if (t != 'd' && t != 'f' && t != 't' && t != 's') {
		xsnprintf(error, sizeof error,
		    "EINVAL:Unknown transmission type: %c", t);
		return (error);
	}
	if (o != 0 && o != 'z') {
		xsnprintf(error, sizeof error,
		    "EINVAL:Unknown image compression: %c", o);
		return (error);
	}
	if (f != 24 && f != 32 && f != 100) {
		xsnprintf(error, sizeof error,
		    "EINVAL:Unknown image format: %u", f);
		return (error);
	}
	if (f == 100 || o == 'z')
		return (NULL);
	if (w == 0 || h == 0)
		return ("EINVAL:Zero width/height not allowed");
	have = len / 4 * 3;
	if (len >= 1 && data[len - 1] == '=')
		have--;
	if (len >= 2 && data[len - 2] == '=')
		have--;
	need = (size_t)w * h * (f / 8);
	if (have < need) {
		xsnprintf(error, sizeof error,
		    "ENODATA:Insufficient image data: %zu < %zu", have, need);
		return (error);
	}
	return (NULL);
}

/* The size in pixels of PNG data (base64), from its header. */
static void
kgfx_png_size(const char *data, u_int *width, u_int *height)
{
	char	 head[33];
	u_char	 b[24];

	if (strlen(data) < 32)
		return;
	memcpy(head, data, 32);
	head[32] = '\0';
	if (b64_pton(head, b, sizeof b) < 24)
		return;
	if (memcmp(b, "\211PNG\r\n\032\n", 8) != 0 || memcmp(b + 12, "IHDR", 4))
		return;
	*width = ((u_int)b[16] << 24)|(b[17] << 16)|(b[18] << 8)|b[19];
	*height = ((u_int)b[20] << 24)|(b[21] << 16)|(b[22] << 8)|b[23];
}

/* Transmit an image (a=t or a=T). */
static struct kgfx_image *
kgfx_transmit(struct window_pane *wp, struct bufferevent *bev,
    struct kgfx_cmd *cmd)
{
	struct kgfx_image	*im;
	u_int			 id = kgfx_number(cmd, 'i', 0);
	u_int			 number = kgfx_number(cmd, 'I', 0);
	char			 t = kgfx_char(cmd, 't', 'd');
	u_int			 f = kgfx_number(cmd, 'f', 32);
	char			*data;
	const char		*error;

	if (t == 'd')
		data = xstrdup(cmd->payload);
	else if (t == 'f' || t == 't' || t == 's') {
		data = kgfx_read_medium(t, cmd->payload, cmd, &error);
		if (data == NULL) {
			kgfx_reply(bev, cmd, id, number, 0, error);
			return (NULL);
		}
	} else
		data = xstrdup("");
	if ((error = kgfx_check(cmd, data)) != NULL) {
		kgfx_reply(bev, cmd, id, number, 0, error);
		free(data);
		return (NULL);
	}

	/* The same id replaces the image, and its placements go. */
	if ((im = kgfx_find(wp->id, id)) != NULL)
		kgfx_delete_image(wp, im, 1);

	im = xcalloc(1, sizeof *im);
	TAILQ_INIT(&im->placements);
	if ((im->gid = kgfx_new_gid()) == 0) {
		free(im);
		free(data);
		kgfx_reply(bev, cmd, id, number, 0, "ENOSPC:too many images");
		return (NULL);
	}
	im->pane = wp->id;
	im->number = number;
	im->id = (id != 0 || number == 0) ? id : im->gid;
	im->order = ++kgfx_order;
	im->keys = kgfx_keys(cmd, "fsvoN");
	im->data = data;
	im->size = strlen(data);
	if (f == 100)
		kgfx_png_size(data, &im->width, &im->height);
	else {
		im->width = kgfx_number(cmd, 's', 0);
		im->height = kgfx_number(cmd, 'v', 0);
	}
	while (kgfx_count >= KGFX_MAXIMAGES)
		kgfx_delete_image(NULL, TAILQ_FIRST(&kgfx_images), 1);
	TAILQ_INSERT_TAIL(&kgfx_images, im, entry);
	kgfx_count++;
	kgfx_size += im->size;
	log_debug("%s: %%%u image %u (number %u) is %u, %zu bytes, %ux%u",
	    __func__, wp->id, im->id, number, im->gid, im->size, im->width,
	    im->height);

	kgfx_send_image(NULL, im);
	kgfx_quota();
	return (im);
}

/* Write a placeholder cell for a row and column of a placement. */
static void
kgfx_cell(struct screen_write_ctx *ctx, struct kgfx_image *im,
    struct kgfx_placement *pl, u_int row, u_int column)
{
	struct grid_cell	 gc;
	struct utf8_data	 ud, part;

	memcpy(&gc, &grid_default_cell, sizeof gc);
	gc.fg = colour_join_rgb(im->gid >> 16, im->gid >> 8, im->gid);
	gc.us = colour_join_rgb(pl->gpid >> 16, pl->gpid >> 8, pl->gpid);

	utf8_fromwc(0x10eeee, &ud);
	utf8_fromwc(kgfx_diacritics[row], &part);
	memcpy(ud.data + ud.size, part.data, part.size);
	ud.size += part.size;
	utf8_fromwc(kgfx_diacritics[column], &part);
	memcpy(ud.data + ud.size, part.data, part.size);
	ud.size += part.size;
	ud.have = ud.size;
	ud.width = 1;
	utf8_copy(&gc.data, &ud);
	screen_write_cell(ctx, &gc);
}

/*
 * Whether a cell is a placeholder, and for which image and placement (tmux's
 * ids).
 */
static int
kgfx_is_cell(struct grid_cell *gc, u_int *gid, u_int *gpid)
{
	u_char	r, g, b;

	if (gc->data.size < 4 || memcmp(gc->data.data, "\364\216\273\256", 4))
		return (0);
	if (~gc->fg & COLOUR_FLAG_RGB)
		return (0);
	colour_split_rgb(gc->fg, &r, &g, &b);
	*gid = (r << 16)|(g << 8)|b;
	*gpid = 0;
	if (gc->us & COLOUR_FLAG_RGB) {
		colour_split_rgb(gc->us, &r, &g, &b);
		*gpid = (r << 16)|(g << 8)|b;
	}
	return (1);
}

/*
 * Clear a pane's placeholder cells of an image (and a placement, if gpid is
 * not 0), in the rows from first to last (absolute, including history).
 */
static void
kgfx_clear_cells(struct window_pane *wp, u_int gid, u_int gpid, u_int first,
    u_int last)
{
	struct grid		*gd = wp->base.grid;
	struct grid_cell	 gc;
	u_int			 x, y, cgid, cgpid;
	int			 changed = 0;

	if (last >= gd->hsize + gd->sy)
		last = gd->hsize + gd->sy - 1;
	for (y = first; y <= last; y++) {
		for (x = 0; x < grid_get_line(gd, y)->cellsize; x++) {
			grid_get_cell(gd, x, y, &gc);
			if (!kgfx_is_cell(&gc, &cgid, &cgpid))
				continue;
			if (cgid != gid || (gpid != 0 && cgpid != gpid))
				continue;
			grid_set_cell(gd, x, y, &grid_default_cell);
			changed = 1;
		}
	}
	if (changed)
		wp->flags |= PANE_REDRAW;
}

/* An image or placement id from a colour (38;5;N, a basic colour or RGB). */
static u_int
kgfx_colour_id(int colour)
{
	u_char	r, g, b;

	if (colour & COLOUR_FLAG_RGB) {
		colour_split_rgb(colour, &r, &g, &b);
		return ((r << 16)|(g << 8)|b);
	}
	if (colour & COLOUR_FLAG_256)
		return (colour & 0xff);
	if (colour >= 0 && colour <= 7)
		return (colour);
	if (colour >= 90 && colour <= 97)
		return (colour - 90 + 8);
	return (0);
}

/*
 * A placeholder cell a program writes itself: its colours name the
 * program's image and placement, which become tmux's.
 */
void
kgfx_placeholder(struct window_pane *wp, struct grid_cell *gc)
{
	struct kgfx_image	*im;
	struct kgfx_placement	*pl;
	u_int			 id, p;

	id = kgfx_colour_id(gc->fg);
	if ((im = kgfx_find(wp->id, id)) == NULL)
		return;
	gc->fg = colour_join_rgb(im->gid >> 16, im->gid >> 8, im->gid);
	p = kgfx_colour_id(gc->us);
	if (p == 0)
		return;
	TAILQ_FOREACH(pl, &im->placements, entry) {
		if (pl->id == p) {
			gc->us = colour_join_rgb(pl->gpid >> 16, pl->gpid >> 8,
			    pl->gpid);
			return;
		}
	}
}

/* Remove a placement: its cells go and terminals delete it. */
static void
kgfx_delete_placement(struct window_pane *wp, struct kgfx_image *im,
    struct kgfx_placement *pl)
{
	char	*s;

	if (wp != NULL && !pl->virtual) {
		kgfx_clear_cells(wp, im->gid, pl->gpid, 0,
		    wp->base.grid->hsize + wp->base.grid->sy - 1);
	}
	xasprintf(&s, "\033_Ga=d,d=i,q=2,i=%u,p=%u\033\\", im->gid, pl->gpid);
	kgfx_send(NULL, s);
	free(s);
	TAILQ_REMOVE(&im->placements, pl, entry);
	free(pl->keys);
	free(pl);
}

/* Remove an image (with its placements; its data too if data is set). */
static void
kgfx_delete_image(struct window_pane *wp, struct kgfx_image *im, int data)
{
	struct kgfx_placement	*pl, *pl1;
	char			*s;

	TAILQ_FOREACH_SAFE(pl, &im->placements, entry, pl1)
		kgfx_delete_placement(wp, im, pl);
	if (!data)
		return;
	xasprintf(&s, "\033_Ga=d,d=I,q=2,i=%u\033\\", im->gid);
	kgfx_send(NULL, s);
	free(s);
	TAILQ_REMOVE(&kgfx_images, im, entry);
	kgfx_count--;
	kgfx_size -= im->size;
	free(im->keys);
	free(im->data);
	free(im);
}

/* The pane has gone: its images go too. */
void
kgfx_pane_free(struct window_pane *wp)
{
	struct kgfx_image	*im, *im1;
	struct kgfx_pending	*pd, *pd1;

	TAILQ_FOREACH_SAFE(im, &kgfx_images, entry, im1) {
		if (im->pane == wp->id)
			kgfx_delete_image(NULL, im, 1);
	}
	TAILQ_FOREACH_SAFE(pd, &kgfx_pendings, entry, pd1) {
		if (pd->pane != wp->id)
			continue;
		TAILQ_REMOVE(&kgfx_pendings, pd, entry);
		kgfx_free_cmd(pd->first);
		evbuffer_free(pd->data);
		free(pd);
	}
}

/* The columns and rows of a placement, from c and r or the image's size. */
static void
kgfx_cells(struct window_pane *wp, struct kgfx_image *im,
    struct kgfx_cmd *cmd, u_int *columns, u_int *rows)
{
	u_int	cx = wp->window->xpixel, cy = wp->window->ypixel;
	u_int	w = kgfx_number(cmd, 'w', 0), h = kgfx_number(cmd, 'h', 0);
	u_int	x = kgfx_number(cmd, 'x', 0), y = kgfx_number(cmd, 'y', 0);

	*columns = kgfx_number(cmd, 'c', 0);
	*rows = kgfx_number(cmd, 'r', 0);

	/* The area of the image shown. */
	if (w == 0 || x + w > im->width)
		w = (x < im->width) ? im->width - x : 0;
	if (h == 0 || y + h > im->height)
		h = (y < im->height) ? im->height - y : 0;

	if (cx == 0)
		cx = DEFAULT_XPIXEL;
	if (cy == 0)
		cy = DEFAULT_YPIXEL;
	if (w != 0 && h != 0) {
		if (*columns == 0 && *rows == 0) {
			*columns = (w + cx - 1) / cx;
			*rows = (h + cy - 1) / cy;
		} else if (*columns == 0) {
			*columns = ((unsigned long long)*rows * cy * w +
			    (unsigned long long)h * cx - 1) /
			    ((unsigned long long)h * cx);
		} else if (*rows == 0) {
			*rows = ((unsigned long long)*columns * cx * h +
			    (unsigned long long)w * cy - 1) /
			    ((unsigned long long)w * cy);
		}
	}
	if (*columns == 0)
		*columns = 1;
	if (*rows == 0)
		*rows = 1;
	if (*columns > KGFX_MAXCELLS)
		*columns = KGFX_MAXCELLS;
	if (*rows > KGFX_MAXCELLS)
		*rows = KGFX_MAXCELLS;
}

/*
 * Display an image (a=p or a=T): a virtual placement if the program asked for
 * one, otherwise a virtual placement and placeholder cells at the cursor, with
 * the cursor moved as kitty moves it.
 */
static void
kgfx_display(struct window_pane *wp, struct screen_write_ctx *ctx,
    struct bufferevent *bev, struct kgfx_cmd *cmd, struct kgfx_image *im)
{
	struct screen		*s = ctx->s;
	struct kgfx_placement	*pl;
	u_int			 p = kgfx_number(cmd, 'p', 0);
	u_int			 columns, rows, row, column, cx, cy, ocy;
	u_int			 sx = screen_size_x(s), sy = screen_size_y(s);
	char			*keys;

	/* The same placement id moves the placement. */
	if (p != 0) {
		TAILQ_FOREACH(pl, &im->placements, entry) {
			if (pl->id == p) {
				kgfx_delete_placement(wp, im, pl);
				break;
			}
		}
	}

	kgfx_cells(wp, im, cmd, &columns, &rows);
	keys = kgfx_keys(cmd, "xywhz");
	pl = xcalloc(1, sizeof *pl);
	pl->id = p;
	pl->gpid = kgfx_new_gpid();
	pl->virtual = (kgfx_number(cmd, 'U', 0) == 1);
	pl->z = kgfx_signed(cmd, 'z', 0);
	xasprintf(&pl->keys, ",c=%u,r=%u%s", columns, rows, keys);
	free(keys);
	TAILQ_INSERT_TAIL(&im->placements, pl, entry);
	kgfx_send_placement(NULL, im, pl);
	kgfx_reply(bev, cmd, im->id, im->number, p, "OK");
	if (pl->virtual)
		return;

	/* Placeholder cells, a row at a time, scrolling at the bottom. */
	cx = s->cx;
	cy = ocy = s->cy;
	if (cx >= sx)
		cx = sx - 1;
	for (row = 0; row < rows; row++) {
		if (row != 0) {
			if (cy == sy - 1) {
				screen_write_cursormove(ctx, cx, cy, 0);
				screen_write_linefeed(ctx, 0, 8);
				if (ocy != 0)
					ocy--;
			} else
				cy++;
		}
		screen_write_cursormove(ctx, cx, cy, 0);
		for (column = 0; column < columns && cx + column < sx; column++)
			kgfx_cell(ctx, im, pl, row, column);
	}

	/* The cursor after the image, unless C=1. */
	if (kgfx_number(cmd, 'C', 0) == 1) {
		screen_write_cursormove(ctx, cx, ocy, 0);
		return;
	}
	if (cx + columns >= sx) {
		screen_write_cursormove(ctx, sx - 1, cy, 0);
		screen_write_carriagereturn(ctx);
		screen_write_linefeed(ctx, 0, 8);
	} else
		screen_write_cursormove(ctx, cx + columns, cy, 0);
}

/*
 * Whether a placement intersects an area of the screen (columns x0 to x1 and
 * rows y0 to y1, 0 based), from its cells.
 */
static int
kgfx_placement_at(struct window_pane *wp, struct kgfx_image *im,
    struct kgfx_placement *pl, u_int x0, u_int x1, u_int y0, u_int y1)
{
	struct grid		*gd = wp->base.grid;
	struct grid_cell	 gc;
	u_int			 x, y, gid, gpid;

	if (pl->virtual)
		return (0);
	for (y = y0; y <= y1 && y < gd->sy; y++) {
		for (x = x0; x <= x1 && x < gd->sx; x++) {
			grid_view_get_cell(gd, x, y, &gc);
			if (kgfx_is_cell(&gc, &gid, &gpid) && gid == im->gid &&
			    gpid == pl->gpid)
				return (1);
		}
	}
	return (0);
}

/* Delete images or placements (a=d). */
static void
kgfx_delete(struct window_pane *wp, struct screen *s, struct kgfx_cmd *cmd)
{
	struct kgfx_image	*im, *im1;
	struct kgfx_placement	*pl, *pl1;
	char			 d = kgfx_char(cmd, 'd', 'a'), lower;
	int			 data = (d >= 'A' && d <= 'Z');
	u_int			 id = kgfx_number(cmd, 'i', 0);
	u_int			 p = kgfx_number(cmd, 'p', 0);
	u_int			 x = kgfx_number(cmd, 'x', 0);
	u_int			 y = kgfx_number(cmd, 'y', 0);
	int			 z = kgfx_signed(cmd, 'z', 0);
	u_int			 sx = screen_size_x(s) - 1, sy = screen_size_y(s) - 1;
	u_int			 x0, x1, y0, y1;
	int			 deleted;
	char			*str;

	lower = data ? d - 'A' + 'a' : d;
	switch (lower) {
	case 'i':
	case 'n':
		if (lower == 'i')
			im = kgfx_find(wp->id, id);
		else
			im = kgfx_find_number(wp->id, kgfx_number(cmd, 'I', 0));
		if (im == NULL)
			return;
		if (p != 0) {
			TAILQ_FOREACH_SAFE(pl, &im->placements, entry, pl1) {
				if (pl->id == p)
					kgfx_delete_placement(wp, im, pl);
			}
		} else
			kgfx_delete_image(wp, im, data);
		return;
	case 'r':
		TAILQ_FOREACH_SAFE(im, &kgfx_images, entry, im1) {
			if (im->pane == wp->id && im->id >= x && im->id <= y)
				kgfx_delete_image(wp, im, data);
		}
		return;
	case 'f':
		if ((im = kgfx_find(wp->id, id)) != NULL) {
			xasprintf(&str, "\033_Ga=d,d=%c,q=2,i=%u\033\\", d,
			    im->gid);
			kgfx_send(NULL, str);
			free(str);
		}
		return;
	case 'a':
		x0 = 0; x1 = sx; y0 = 0; y1 = sy;
		break;
	case 'c':
		x0 = x1 = s->cx; y0 = y1 = s->cy;
		break;
	case 'p':
	case 'q':
		if (x == 0 || y == 0)
			return;
		x0 = x1 = x - 1; y0 = y1 = y - 1;
		break;
	case 'x':
		if (x == 0)
			return;
		x0 = x1 = x - 1; y0 = 0; y1 = sy;
		break;
	case 'y':
		if (y == 0)
			return;
		x0 = 0; x1 = sx; y0 = y1 = y - 1;
		break;
	case 'z':
		x0 = 0; x1 = sx; y0 = 0; y1 = sy;
		break;
	default:
		return;
	}

	/* Placements on the screen: those whose cells are in the area. */
	TAILQ_FOREACH_SAFE(im, &kgfx_images, entry, im1) {
		if (im->pane != wp->id)
			continue;
		deleted = 0;
		TAILQ_FOREACH_SAFE(pl, &im->placements, entry, pl1) {
			if ((lower == 'q' || lower == 'z') && pl->z != z)
				continue;
			if (!kgfx_placement_at(wp, im, pl, x0, x1, y0, y1))
				continue;
			kgfx_delete_placement(wp, im, pl);
			deleted = 1;
		}
		if (data && deleted && TAILQ_EMPTY(&im->placements))
			kgfx_delete_image(wp, im, 1);
	}
}

/*
 * Answer a query (a=q): whether the image would load, without storing it.
 * Until the terminals have said whether they take images, the answer waits.
 */
static void
kgfx_query(struct window_pane *wp, struct bufferevent *bev,
    struct kgfx_cmd *cmd)
{
	char		 t = kgfx_char(cmd, 't', 'd');
	u_int		 id = kgfx_number(cmd, 'i', 0);
	const char	*error;
	char		*data;

	if (t == 'f' || t == 't' || t == 's') {
		data = kgfx_read_medium(t, cmd->payload, cmd, &error);
		if (data == NULL) {
			kgfx_reply(bev, cmd, id, 0, 0, error);
			return;
		}
	} else
		data = xstrdup(t == 'd' ? cmd->payload : "");
	error = kgfx_check(cmd, data);
	free(data);
	if (error != NULL) {
		kgfx_reply(bev, cmd, id, 0, 0, error);
		return;
	}
	if (kgfx_supported(wp) == -1) {
		kgfx_hold(wp, cmd, id);
		return;
	}
	kgfx_reply(bev, cmd, id, 0, 0, "OK");
}

/* An animation command: to terminals, with tmux's id. */
static void
kgfx_animation(struct window_pane *wp, struct bufferevent *bev,
    struct kgfx_cmd *cmd, char a)
{
	struct kgfx_image	*im;
	char			*keys, *s;
	u_int			 id = kgfx_number(cmd, 'i', 0);
	u_int			 number = kgfx_number(cmd, 'I', 0);

	im = (id != 0) ? kgfx_find(wp->id, id) : kgfx_find_number(wp->id,
	    number);
	if (im == NULL) {
		kgfx_reply(bev, cmd, id, number, 0, "ENOENT:no such image");
		return;
	}
	keys = kgfx_keys(cmd, "xywhXYcrszvC");
	if (a == 'f' && *cmd->payload != '\0') {
		xasprintf(&s, "\033_Ga=f,q=2,i=%u%s;%s\033\\", im->gid, keys,
		    cmd->payload);
	} else
		xasprintf(&s, "\033_Ga=%c,q=2,i=%u%s\033\\", a, im->gid, keys);
	kgfx_send(NULL, s);
	free(s);
	free(keys);
	kgfx_reply(bev, cmd, im->id, im->number, 0, "OK");
}

/* Handle a complete command. */
static void
kgfx_run(struct window_pane *wp, struct screen_write_ctx *ctx,
    struct bufferevent *bev, struct kgfx_cmd *cmd)
{
	struct kgfx_image	*im;
	char			 a = kgfx_char(cmd, 'a', 't'), *msg;
	u_int			 id = kgfx_number(cmd, 'i', 0);
	u_int			 number = kgfx_number(cmd, 'I', 0);

	log_debug("%s: %%%u a=%c i=%u I=%u", __func__, wp->id, a, id, number);
	switch (a) {
	case 'q':
		kgfx_query(wp, bev, cmd);
		break;
	case 't':
		if ((im = kgfx_transmit(wp, bev, cmd)) != NULL)
			kgfx_reply(bev, cmd, im->id, im->number, 0, "OK");
		break;
	case 'T':
		if ((im = kgfx_transmit(wp, bev, cmd)) != NULL)
			kgfx_display(wp, ctx, bev, cmd, im);
		break;
	case 'p':
		im = (id != 0) ? kgfx_find(wp->id, id) :
		    kgfx_find_number(wp->id, number);
		if (im == NULL) {
			xasprintf(&msg, "ENOENT:Put command refers to "
			    "non-existent image with id: %u and number: %u",
			    id, number);
			kgfx_reply(bev, cmd, id, number,
			    kgfx_number(cmd, 'p', 0), msg);
			free(msg);
			break;
		}
		kgfx_display(wp, ctx, bev, cmd, im);
		break;
	case 'd':
		kgfx_delete(wp, ctx->s, cmd);
		break;
	case 'f':
	case 'a':
	case 'c':
		kgfx_animation(wp, bev, cmd, a);
		break;
	}
}

/*
 * A kitty graphics command from a pane (the APC string, G...). Terminals that
 * show the pane must have the protocol, or tmux does not have it either.
 */
void
kgfx_command(struct window_pane *wp, struct screen_write_ctx *ctx,
    struct bufferevent *bev, const u_char *buf, size_t len)
{
	struct kgfx_cmd		*cmd;
	struct kgfx_pending	*pd;
	struct client		*c;

	if (kgfx_supported(wp) == 0)
		return;
	if ((cmd = kgfx_parse(buf, len)) == NULL)
		return;

	/* The grid has everything before the command (placeholder cells). */
	screen_write_flush(ctx);

	/* The next chunk of a transmission: m and the data, maybe q. */
	TAILQ_FOREACH(pd, &kgfx_pendings, entry) {
		if (pd->pane == wp->id)
			break;
	}
	if (pd != NULL) {
		evbuffer_add(pd->data, cmd->payload, strlen(cmd->payload));
		if (kgfx_number(cmd, 'm', 0) == 1) {
			kgfx_free_cmd(cmd);
			return;
		}
		kgfx_free_cmd(cmd);
		TAILQ_REMOVE(&kgfx_pendings, pd, entry);
		cmd = pd->first;
		free(cmd->payload);
		evbuffer_add(pd->data, "", 1);
		cmd->payload = xstrdup(EVBUFFER_DATA(pd->data));
		evbuffer_free(pd->data);
		free(pd);
	} else if (kgfx_number(cmd, 'm', 0) == 1) {
		pd = xcalloc(1, sizeof *pd);
		pd->pane = wp->id;
		pd->first = cmd;
		if ((pd->data = evbuffer_new()) == NULL)
			fatalx("out of memory");
		evbuffer_add(pd->data, cmd->payload, strlen(cmd->payload));
		TAILQ_INSERT_TAIL(&kgfx_pendings, pd, entry);
		return;
	}

	kgfx_run(wp, ctx, bev, cmd);
	kgfx_free_cmd(cmd);

	/* The pane is drawn from its grid again where it was forwarded. */
	TAILQ_FOREACH(c, &clients, entry) {
		if (c->forward_pane == wp->id)
			forward_stop(c);
	}
}
