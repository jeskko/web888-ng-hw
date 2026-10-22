// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zsdr-test: exercise every /dev/zynqsdr ioctl of the open web888-sdr
 * driver. Written for the QEMU virtual Web-888 (default scene: a -40 dBFS
 * carrier at 15 MHz, fs 122.88 MHz) but safe on a board.
 *
 *   zsdr-test [-d DEV]    run the checks; one line per check, exit 1 if any
 *                         failed
 *   zsdr-test [-d DEV] --bench SECS [--r2 N] [--adc HZ] [--wf DECIM]
 *                         benchmark (stock ioctls only, so it compares the
 *                         stock and the open driver on the same bitstream):
 *                         RX at stage-2 decimation N (default 5: 96 kS/s
 *                         at 122.88 MHz), read greedily (again at once, like
 *                         the stock server) and paced (5 ms batches, like
 *                         web888d); with --wf also continuous waterfall 0 at
 *                         decimation DECIM, paced
 *   zsdr-test --pl-up     emulator only: set the SLCR as fpga_manager leaves
 *                         it after a load (level shifters on, fabric resets
 *                         released), for the driver's PL readiness check
 *
 * Emulator numbers say nothing about the board (syscalls are ~50x slow).
 */
#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include "../web888_sdr.h"

#define FS		122880000.0
#define RING		(0xff8 * 128)
#define TONE_HZ		15000000.0

static int fd, failed;
static unsigned int nrx;
static int ext;

#define CHECK(cond, ...) do {						\
	int ok_ = !!(cond);						\
	printf("%s ", ok_ ? "PASS" : "FAIL");				\
	printf(__VA_ARGS__);						\
	putchar('\n');							\
	if (!ok_)							\
		failed = 1;						\
} while (0)

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static uint64_t phase(double hz)
{
	return (uint64_t)(hz / FS * 281474976710656.0);	/* 2^48 */
}

/* poll for ev; returns revents (0 on timeout) */
static int wait_ev(short ev, int ms)
{
	struct pollfd p = { .fd = fd, .events = ev };

	if (poll(&p, 1, ms) < 0)
		return -errno;
	return p.revents;
}

static long rx_read(void *buf, uint32_t len)
{
	struct zsdr_rx_read r = { .address = (uint32_t)(uintptr_t)buf,
				  .length = len };

	if (ioctl(fd, ZSDR_RX_READ, &r) < 0)
		return -errno;
	return r.readed;
}

static long wf_read(int ch, void *buf, uint32_t len)
{
	struct zsdr_wf_read r = { .channel = ch,
				  .address = (uint32_t)(uintptr_t)buf,
				  .length = len };

	if (ioctl(fd, ZSDR_WF_READ, &r) < 0)
		return -errno;
	return r.readed;
}

static int stats(struct zsdr_stats *st)
{
	memset(st, 0, sizeof(*st));
	return ioctl(fd, ZSDR_GET_STATS, st);
}

static void t_basic(void)
{
	uint32_t sig = 0, g = 0;
	uint64_t dna = 0;
	struct zsdr_stats st;
	int fd2;

	CHECK(ioctl(fd, ZSDR_GET_SIGNATURE, &sig) == 0, "GET_SIGNATURE 0x%08x", sig);
	nrx = sig & 0xf;
	ext = (sig >> 16) == 0x0e5d;
	CHECK(ioctl(fd, ZSDR_GET_DNA, &dna) == 0 && dna,
	      "GET_DNA 0x%014llx", (unsigned long long)dna);
	CHECK(stats(&st) == 0 && st.size == sizeof(st) && st.signature == sig &&
	      st.ext == (unsigned)ext,
	      "GET_STATS size %u ext %u build %08x", st.size, st.ext, st.build_id);

	CHECK(ioctl(fd, ZSDR_SET_GPIO, 0x15 | ZSDR_GPIO_LED) == 0 &&
	      ioctl(fd, ZSDR_GET_GPIO, &g) == 0 && g == (0x15 | ZSDR_GPIO_LED),
	      "SET_GPIO/GET_GPIO round trip (0x%x)", g);
	ioctl(fd, ZSDR_SET_GPIO, 0);
	CHECK(ioctl(fd, ZSDR_AD8370_SET, 0x2a) == 0, "AD8370_SET 0x2a");
	CHECK(ioctl(fd, ZSDR_MODE_SET, 1) == 0 && ioctl(fd, ZSDR_MODE_SET, 0) == 0,
	      "MODE_SET 1, 0");
	CHECK(ioctl(fd, ZSDR_CLK_SET, 0) == 0, "CLK_SET 0");

	fd2 = open("/dev/zynqsdr", O_RDWR);
	CHECK(fd2 < 0 && errno == EBUSY, "second open: EBUSY");
	if (fd2 >= 0)
		close(fd2);
	CHECK(ioctl(fd, ZSDR_RX_START, 4) < 0 && errno == EINVAL, "RX_START 4: EINVAL");
	CHECK(ioctl(fd, ZSDR_RX_START, ext ? 64 : 41) < 0 && errno == EINVAL,
	      "RX_START above max: EINVAL");
	CHECK(ioctl(fd, ZSDR_WF_START, 2) < 0 && errno == EINVAL, "WF_START 2: EINVAL");
	CHECK(ioctl(fd, _IO(ZSDR_IOC_TYPE, 0x3f)) < 0 && errno == ENOTTY,
	      "unknown ioctl: ENOTTY");
	{
		char b[128];

		CHECK(rx_read(b, sizeof(b)) == -EINVAL, "RX_READ while stopped: EINVAL");
		CHECK(wf_read(0, b, sizeof(b)) == -EINVAL, "WF_READ while stopped: EINVAL");
	}
}

/* RX: ch0 on the carrier (+1 kHz), the others far away */
static void rx_setup(unsigned int r2)
{
	unsigned int c;

	for (c = 0; c < nrx; c++) {
		struct zsdr_rx_param p = { .channel = c,
			.freq = phase(c ? 1000000.0 + 100000.0 * c : TONE_HZ - 1000.0) };

		ioctl(fd, ZSDR_RX_PARAM, &p);
	}
	ioctl(fd, ZSDR_RX_START, r2);
}

/*
 * Mean |I|+|Q| per channel slot, with the slot of each byte taken from the
 * stream position pos (bytes since start, including skipped ones).
 */
static int loudest_slot(const int32_t *s, size_t words, uint64_t pos)
{
	double sum[16] = { 0 };
	unsigned int fw = 2 * nrx, w0 = (pos / 4) % fw, i, best = 0;

	for (i = 0; i < words; i++)
		sum[((w0 + i) % fw) / 2] += abs(s[i]);
	for (i = 1; i < nrx; i++)
		if (sum[i] > sum[best])
			best = i;
	return best;
}

/* channel 0 power (dB, arbitrary) over ~frames frames after a restart */
static double rx_ch0_db(int32_t *buf, long frames)
{
	long fb = 8 * nrx, got = 0, n, i;
	double p = 0;

	ioctl(fd, ZSDR_RX_START, 10);
	while (got < fb * frames) {
		wait_ev(POLLIN, 500);
		n = rx_read((char *)buf + got, fb * frames - got);
		if (n <= 0)
			return -999;
		got += n;
	}
	/* skip the first half: filter settling */
	for (i = frames / 2; i < frames; i++) {
		double re = buf[i * 2 * nrx], im = buf[i * 2 * nrx + 1];

		p += re * re + im * im;
	}
	return 10 * log10(p / (frames - frames / 2) + 1e-30);
}

static void t_rx(void)
{
	static int32_t buf[RING / 4];
	struct zsdr_rx_param bad = { .channel = nrx, .freq = 0 };
	double t0, t = 0;
	long n, total = 0;
	int ev;

	CHECK(ioctl(fd, ZSDR_RX_PARAM, &bad) < 0 && errno == EINVAL,
	      "RX_PARAM channel %u: EINVAL", nrx);
	rx_setup(10);		/* 48 kS/s */
	ev = wait_ev(POLLIN, 2000);
	CHECK(ev & POLLIN, "RX poll(): POLLIN (revents 0x%x)", ev);

	t0 = now();
	do {
		wait_ev(POLLIN, 500);
		n = rx_read(buf, 65536);
		if (n < 0)
			break;
		total += n;
		t = now();
	} while (t - t0 < 1.0);
	CHECK(n >= 0 && total > 0, "RX_READ %ld bytes in %.2f s (%.0f frames/s)",
	      total, t - t0, total / (8.0 * nrx) / (t - t0));

	{
		/* a fresh start: the carrier must be in slot 0 */
		long got = 0;

		ioctl(fd, ZSDR_RX_START, 10);
		while (got < 8 * (long)nrx * 2000) {
			wait_ev(POLLIN, 500);
			n = rx_read((char *)buf + got, 8 * nrx * 2000 - got);
			if (n <= 0)
				break;
			got += n;
		}
		CHECK(got && loudest_slot(buf, got / 4, 0) == 0,
		      "RX carrier in channel 0 (%ld bytes)", got);
	}

	{
		/* PE4312 step attenuator: code = 2 x dB */
		double a, b;

		ioctl(fd, ZSDR_AD8370_SET, 0);
		a = rx_ch0_db(buf, 4000);
		ioctl(fd, ZSDR_AD8370_SET, 20);
		b = rx_ch0_db(buf, 4000);
		ioctl(fd, ZSDR_AD8370_SET, 0);
		CHECK(fabs(a - b - 10) < 0.5, "AD8370_SET 20: carrier %.2f dB lower", a - b);
	}
}

/* lap the ring, then check the skip kept the frame alignment */
static void t_rx_overrun(void)
{
	static int32_t buf[RING / 4];
	struct zsdr_stats a, b;
	long n, got = 0;
	int slot;

	if (!ext) {
		printf("SKIP RX overrun (stock bitstream)\n");
		return;
	}
	rx_setup(5);		/* 96 kS/s: laps the ring in ~60 ms */
	stats(&a);
	usleep(1500000);
	while (got < 8 * (long)nrx * 4000) {
		wait_ev(POLLIN, 500);
		n = rx_read((char *)buf + got, 8 * nrx * 4000 - got);
		if (n <= 0)
			break;
		got += n;
	}
	stats(&b);
	CHECK(b.rx_overruns > a.rx_overruns && b.rx_overrun_bytes > a.rx_overrun_bytes,
	      "RX overrun counted (%u, %llu bytes skipped)", b.rx_overruns - a.rx_overruns,
	      (unsigned long long)(b.rx_overrun_bytes - a.rx_overrun_bytes));
	CHECK((b.rx_overrun_bytes - a.rx_overrun_bytes) % (8 * nrx) == 0,
	      "RX skip is whole frames");
	/* the skip happened at the first read: stream position = skipped bytes */
	slot = loudest_slot(buf, got / 4, b.rx_overrun_bytes - a.rx_overrun_bytes);
	CHECK(got && slot == 0, "RX carrier still in channel 0 after the skip (slot %d)",
	      slot);
	CHECK(b.rx_bursts > 0 && b.rx_frames > 0, "STATS rx_bursts %u rx_frames %u",
	      b.rx_bursts, b.rx_frames);
	ioctl(fd, ZSDR_RX_START, 10);
}

/* close and open again: stops every stream */
static void reopen(void)
{
	close(fd);
	fd = open("/dev/zynqsdr", O_RDWR);
	if (fd < 0) {
		printf("FAIL reopen: %s\n", strerror(errno));
		exit(1);
	}
}

static void t_wf(int ch)
{
	static int16_t buf[RING / 2];
	struct zsdr_wf_param p = { .channel = ch, .decimate = 16,
				   .freq = phase(TONE_HZ - 100000.0) };
	struct zsdr_wf_param bad = { .channel = ch, .decimate = 0 };
	long n, got = 0;
	double t0;

	CHECK(ioctl(fd, ZSDR_WF_PARAM, &bad) < 0 && errno == EINVAL,
	      "WF%d_PARAM decimate 0: EINVAL", ch);
	CHECK(ioctl(fd, ZSDR_WF_PARAM, &p) == 0, "WF%d_PARAM", ch);

	/* one-shot: exactly 8192 samples, then nothing */
	ioctl(fd, ZSDR_WF_START, ch);
	t0 = now();
	while (now() - t0 < 2.0) {
		wait_ev(POLLIN, 200);
		n = wf_read(ch, (char *)buf + got, sizeof(buf) - got);
		if (n < 0)
			break;
		got += n;
	}
	CHECK(got == 8192 * 4, "WF%d one-shot: %ld bytes (want %d)", ch, got, 8192 * 4);
	CHECK(wait_ev(POLLIN, 300) == 0, "WF%d one-shot done: no POLLIN", ch);

	/* continuous: keeps coming */
	ioctl(fd, ZSDR_WF_START, ch | ZSDR_WF_READ_CONTINUES);
	wf_read(ch, buf, sizeof(buf));
	t0 = now();
	n = wait_ev(POLLIN, 2000);
	t0 = now() - t0;
	CHECK((n & POLLIN) && t0 < 0.5, "WF%d poll(): POLLIN by interrupt after %.3f s",
	      ch, t0);
	got = 0;
	t0 = now();
	while (now() - t0 < 1.0) {
		wait_ev(POLLIN, 200);
		n = wf_read(ch, buf, sizeof(buf));
		if (n < 0)
			break;
		got += n;
	}
	CHECK(got > 8192 * 4, "WF%d continuous: %ld bytes in 1 s", ch, got);
	ioctl(fd, ZSDR_WF_START, ch);	/* back to one-shot (stops after a block) */
}

static void t_pps(void)
{
	uint32_t v = 0, v2 = 0;
	int ev;

	/* (re)starting clears the FIFO */
	CHECK(ioctl(fd, ZSDR_PPS_START, 1) == 0, "PPS_START 1");
	CHECK(ioctl(fd, ZSDR_PPS_READ, &v) < 0 && errno == EBUSY,
	      "PPS_READ right after start: EBUSY");
	/* the first edge only arms the counter: the first period is the second */
	{
		double t0 = now();

		ev = wait_ev(POLLPRI, 3500);
		t0 = now() - t0;
		/* the second edge after the start: within 2 s, by interrupt */
		CHECK((ev & POLLPRI) && t0 < 2.5, "PPS poll(): POLLPRI after %.2f s (revents 0x%x)",
		      t0, ev);
	}
	CHECK(ioctl(fd, ZSDR_PPS_READ, &v) == 0 && v > FS * 0.999 && v < FS * 1.001,
	      "PPS_READ %u", v);
	CHECK(ioctl(fd, ZSDR_PPS_READ, &v2) < 0 && errno == EBUSY,
	      "PPS_READ again: EBUSY");
	ioctl(fd, ZSDR_PPS_START, 0);
}

/* ------------------------------------------------------------- benchmark */

static double cpu_secs(const struct timeval *t)
{
	return t->tv_sec + t->tv_usec * 1e-6;
}

struct bench {
	double secs, bytes, t_io, t_max, user, sys;
	long reads, empty;
	int have_stats;			/* open driver */
	struct zsdr_stats s0, s1;
};

static void bench_begin(struct bench *b, struct rusage *ru)
{
	memset(b, 0, sizeof(*b));
	b->have_stats = stats(&b->s0) == 0;
	getrusage(RUSAGE_SELF, ru);
	b->secs = now();
}

static void bench_end(struct bench *b, const struct rusage *ru0)
{
	struct rusage ru;

	if (b->have_stats)
		stats(&b->s1);
	getrusage(RUSAGE_SELF, &ru);
	b->secs = now() - b->secs;
	b->user = (cpu_secs(&ru.ru_utime) - cpu_secs(&ru0->ru_utime)) / b->secs;
	b->sys = (cpu_secs(&ru.ru_stime) - cpu_secs(&ru0->ru_stime)) / b->secs;
}

/* account one timed read of n bytes (or -errno) that took d seconds */
static int bench_add(struct bench *b, long n, double d)
{
	if (n < 0) {
		printf("bench: read failed: %s\n", strerror(-n));
		return -1;
	}
	b->reads++;
	b->empty += !n;
	b->bytes += n;
	b->t_io += d;
	if (d > b->t_max)
		b->t_max = d;
	return 0;
}

/* sleep for the rest of a batch of `ms` at `bps` bytes/s after n bytes */
static void pace(int ms, double bps, long n)
{
	double want = ms * 1e-3 * bps;

	if (n < want)
		usleep((useconds_t)((want - n) / bps * 1e6));
}

static void bench_print(const char *what, const struct bench *b, double bps)
{
	printf("%-12s %6.1f %% of %.0f B/s, %7.0f reads/s (%4.1f %% empty), "
	       "%6.0f B/read\n", what, 100.0 * b->bytes / b->secs / bps, bps,
	       b->reads / b->secs, 100.0 * b->empty / (b->reads ? b->reads : 1),
	       b->bytes / (b->reads ? b->reads : 1));
	printf("%-12s ioctl %6.1f us mean, %7.1f us max; copy %6.1f MB/s; "
	       "CPU %5.1f %% (user %4.1f, sys %5.1f)\n", "",
	       1e6 * b->t_io / (b->reads ? b->reads : 1), 1e6 * b->t_max,
	       b->bytes / (b->t_io > 0 ? b->t_io : 1) / 1e6,
	       100 * (b->user + b->sys), 100 * b->user, 100 * b->sys);
	if (b->have_stats && b->s1.rx_overruns != b->s0.rx_overruns)
		printf("%-12s %u RX overruns, %llu bytes skipped\n", "",
		       b->s1.rx_overruns - b->s0.rx_overruns,
		       (unsigned long long)(b->s1.rx_overrun_bytes - b->s0.rx_overrun_bytes));
}

static void bench_rx(unsigned int r2, double adc, double secs, int paced_ms)
{
	static char buf[RING];
	double bps = adc / (256.0 * r2) * 8 * nrx, t;
	struct bench b;
	struct rusage ru;
	unsigned int c;
	long n;

	for (c = 0; c < nrx; c++) {
		struct zsdr_rx_param p = { .channel = c,
					   .freq = phase(1000000.0 * (c + 1)) };

		ioctl(fd, ZSDR_RX_PARAM, &p);
	}
	if (ioctl(fd, ZSDR_RX_START, r2) < 0) {
		printf("bench: RX_START %u: %s\n", r2, strerror(errno));
		return;
	}
	usleep(100000);
	rx_read(buf, sizeof(buf));	/* start from an empty ring (may skip) */
	bench_begin(&b, &ru);
	do {
		t = now();
		n = rx_read(buf, sizeof(buf));
		if (bench_add(&b, n, now() - t))
			break;
		if (paced_ms)
			pace(paced_ms, bps, n);
	} while (now() - b.secs < secs);
	bench_end(&b, &ru);
	bench_print(paced_ms ? "RX paced" : "RX greedy", &b, bps);
}

static void bench_wf(unsigned int decim, double adc, double secs)
{
	static char buf[RING];
	struct zsdr_wf_param p = { .channel = 0, .decimate = decim,
				   .freq = phase(10000000.0) };
	double bps = adc / decim * 4, t;
	struct bench b;
	struct rusage ru;
	long n;

	if (ioctl(fd, ZSDR_WF_PARAM, &p) < 0 ||
	    ioctl(fd, ZSDR_WF_START, ZSDR_WF_READ_CONTINUES) < 0) {
		printf("bench: WF start: %s\n", strerror(errno));
		return;
	}
	usleep(100000);
	wf_read(0, buf, sizeof(buf));
	bench_begin(&b, &ru);
	do {
		t = now();
		n = wf_read(0, buf, sizeof(buf));
		if (bench_add(&b, n, now() - t))
			break;
		pace(5, bps, n);
	} while (now() - b.secs < secs);
	bench_end(&b, &ru);
	bench_print("WF0 paced", &b, bps);
	ioctl(fd, ZSDR_WF_START, 0);	/* one-shot: stops after a block */
}

static int bench(double secs, unsigned int r2, double adc, unsigned int wf_decim)
{
	struct zsdr_stats st;
	uint32_t sig = 0;
	int have;

	ioctl(fd, ZSDR_GET_SIGNATURE, &sig);
	nrx = sig & 0xf;
	have = stats(&st) == 0;
	printf("bench: signature 0x%08x, %u RX channels, R2 %u (%.0f frames/s), "
	       "%s driver, %.0f s per run\n", sig, nrx, r2, adc / (256.0 * r2),
	       have ? "open" : "stock", secs);
	bench_rx(r2, adc, secs, 0);
	bench_rx(r2, adc, secs, 5);
	if (wf_decim)
		bench_wf(wf_decim, adc, secs);
	if (have && stats(&st) == 0 && st.ext)
		printf("FPGA: %u RX frames dropped in the FIFO since the last start\n",
		       st.rx_frames_dropped);
	return 0;
}

static int pl_up(void)
{
	int m = open("/dev/mem", O_RDWR | O_SYNC);
	volatile uint32_t *slcr;

	if (m < 0) {
		perror("/dev/mem");
		return 1;
	}
	slcr = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, m, 0xf8000000);
	if (slcr == MAP_FAILED) {
		perror("mmap SLCR");
		return 1;
	}
	slcr[0x008 / 4] = 0xdf0d;	/* SLCR_UNLOCK */
	slcr[0x900 / 4] = 0xf;		/* LVL_SHFTR_EN */
	slcr[0x240 / 4] = 0;		/* FPGA_RST_CTRL */
	slcr[0x004 / 4] = 0x767b;	/* SLCR_LOCK */
	printf("SLCR: level shifters 0x%x, fabric resets 0x%x\n",
	       slcr[0x900 / 4], slcr[0x240 / 4]);
	return 0;
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/zynqsdr";
	double bench_secs = 0, adc = FS;
	unsigned int r2 = 5, wf_decim = 0;
	int i;

	setvbuf(stdout, NULL, _IOLBF, 0);
	for (i = 1; i < argc; i++) {
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;

		if (!strcmp(argv[i], "--pl-up"))
			return pl_up();
		if (!v) {
			fprintf(stderr, "usage: see the comment at the top of zsdr-test.c\n");
			return 2;
		}
		if (!strcmp(argv[i], "-d"))
			dev = v;
		else if (!strcmp(argv[i], "--bench"))
			bench_secs = atof(v);
		else if (!strcmp(argv[i], "--r2"))
			r2 = atoi(v);
		else if (!strcmp(argv[i], "--adc"))
			adc = atof(v);
		else if (!strcmp(argv[i], "--wf"))
			wf_decim = atoi(v);
		else {
			fprintf(stderr, "unknown option %s\n", argv[i]);
			return 2;
		}
		i++;
	}
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("FAIL open %s: %s\n", dev, strerror(errno));
		return 1;
	}
	if (bench_secs > 0)
		return bench(bench_secs, r2, adc, wf_decim);
	t_basic();
	t_rx();
	t_rx_overrun();
	reopen();
	t_wf(0);
	reopen();
	t_wf(1);
	reopen();
	t_pps();
	rx_setup(10);	/* PPS again, with RX data always ready */
	t_pps();
	close(fd);
	printf(failed ? "FAILED\n" : "ALL PASSED\n");
	return failed;
}
