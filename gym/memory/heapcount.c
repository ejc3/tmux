/*
 * heapcount: LD_PRELOAD into a process to count its live heap exactly.
 *
 * Every malloc-family call is passed to glibc and counted: live bytes (as
 * malloc_usable_size reports them), live blocks and the peak of live bytes.
 * On HEAPCOUNT_SIGNAL (SIGRTMIN+5) the process writes
 *
 *	<seq> <live bytes> <live blocks> <peak bytes since last report>
 *
 * to $HEAPCOUNT_DIR/<pid> (written to a temporary name, then renamed) and
 * starts a new peak. The handler uses only async-signal-safe calls, so it is
 * safe whatever the process was doing. The variables are cleared from the
 * environment at load, so children the process starts (a tmux server's
 * panes) are not counted; the process itself and its forks keep counting.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <malloc.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void	*__libc_malloc(size_t);
extern void	*__libc_calloc(size_t, size_t);
extern void	*__libc_realloc(void *, size_t);
extern void	 __libc_free(void *);
extern void	*__libc_memalign(size_t, size_t);
extern void	*__libc_valloc(size_t);
extern void	*__libc_pvalloc(size_t);

static volatile int64_t	live_bytes;
static volatile int64_t	live_blocks;
static volatile int64_t	peak_bytes;
static volatile int64_t	seq;
static char		dir[1024];

static void
grow(int64_t bytes, int64_t blocks)
{
	int64_t	now, peak;

	now = __atomic_add_fetch(&live_bytes, bytes, __ATOMIC_RELAXED);
	__atomic_add_fetch(&live_blocks, blocks, __ATOMIC_RELAXED);
	peak = __atomic_load_n(&peak_bytes, __ATOMIC_RELAXED);
	while (now > peak && !__atomic_compare_exchange_n(&peak_bytes, &peak,
	    now, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
		;
}

static void
added(void *p)
{
	if (p != NULL)
		grow(malloc_usable_size(p), 1);
}

void *
malloc(size_t n)
{
	void	*p = __libc_malloc(n);

	added(p);
	return (p);
}

void *
calloc(size_t n, size_t size)
{
	void	*p = __libc_calloc(n, size);

	added(p);
	return (p);
}

void
free(void *p)
{
	if (p != NULL)
		grow(-(int64_t)malloc_usable_size(p), -1);
	__libc_free(p);
}

void *
realloc(void *p, size_t n)
{
	size_t	 old;
	void	*q;

	if (p == NULL)
		return (malloc(n));
	old = malloc_usable_size(p);
	q = __libc_realloc(p, n);
	if (q != NULL)
		grow((int64_t)malloc_usable_size(q) - (int64_t)old, 0);
	else if (n == 0)
		grow(-(int64_t)old, -1);	/* glibc frees p */
	return (q);
}

void *
reallocarray(void *p, size_t n, size_t size)
{
	if (size != 0 && n > SIZE_MAX / size) {
		errno = ENOMEM;
		return (NULL);
	}
	return (realloc(p, n * size));
}

void *
memalign(size_t align, size_t n)
{
	void	*p = __libc_memalign(align, n);

	added(p);
	return (p);
}

void *
aligned_alloc(size_t align, size_t n)
{
	return (memalign(align, n));
}

int
posix_memalign(void **pp, size_t align, size_t n)
{
	void	*p;

	if (align < sizeof (void *) || (align & (align - 1)) != 0)
		return (EINVAL);
	p = memalign(align, n);
	if (p == NULL)
		return (ENOMEM);
	*pp = p;
	return (0);
}

void *
valloc(size_t n)
{
	void	*p = __libc_valloc(n);

	added(p);
	return (p);
}

void *
pvalloc(size_t n)
{
	void	*p = __libc_pvalloc(n);

	added(p);
	return (p);
}

/* Append decimal v to buf at *at (async-signal-safe). */
static void
put(char *buf, size_t *at, int64_t v)
{
	char	tmp[24];
	int	n = 0;

	if (v < 0) {
		buf[(*at)++] = '-';
		v = -v;
	}
	do
		tmp[n++] = '0' + v % 10;
	while ((v /= 10) != 0);
	while (n > 0)
		buf[(*at)++] = tmp[--n];
}

static void
puts_at(char *buf, size_t *at, const char *s)
{
	while (*s != '\0')
		buf[(*at)++] = *s++;
}

static void
report(int sig)
{
	char	line[128], path[1100], tmp[1110];
	size_t	n = 0, p = 0, t = 0;
	int	fd, saved = errno;
	int64_t	now;

	(void)sig;
	now = __atomic_load_n(&live_bytes, __ATOMIC_RELAXED);
	put(line, &n, __atomic_add_fetch(&seq, 1, __ATOMIC_RELAXED));
	line[n++] = ' ';
	put(line, &n, now);
	line[n++] = ' ';
	put(line, &n, __atomic_load_n(&live_blocks, __ATOMIC_RELAXED));
	line[n++] = ' ';
	put(line, &n, __atomic_exchange_n(&peak_bytes, now, __ATOMIC_RELAXED));
	line[n++] = '\n';

	puts_at(path, &p, dir);
	path[p++] = '/';
	put(path, &p, getpid());
	path[p] = '\0';
	puts_at(tmp, &t, path);
	puts_at(tmp, &t, ".tmp");
	tmp[t] = '\0';

	fd = open(tmp, O_WRONLY|O_CREAT|O_TRUNC, 0600);
	if (fd != -1) {
		if (write(fd, line, n) == (ssize_t)n)
			rename(tmp, path);
		close(fd);
	}
	errno = saved;
}

__attribute__((constructor)) static void
heapcount_init(void)
{
	struct sigaction	 sa;
	const char		*d = getenv("HEAPCOUNT_DIR");

	if (d == NULL || strlen(d) >= sizeof dir)
		return;
	strcpy(dir, d);
	unsetenv("HEAPCOUNT_DIR");
	unsetenv("LD_PRELOAD");

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = report;
	sa.sa_flags = SA_RESTART;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGRTMIN + 5, &sa, NULL);
}
