// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zsdr-test: exercise every /dev/zynqsdr ioctl of the open web888-sdr
 * driver. Written for the QEMU virtual Web-888 (default scene: a -40 dBFS
 * carrier at 15 MHz, fs 122.88 MHz) but safe on a board.
 *
 *   zsdr-test [-d /dev/zynqsdr]
 *   zsdr-test --pl-up     emulator only: set the SLCR as fpga_manager leaves
 *                         it after a load (level shifters on, fabric resets
 *                         released), for the driver's PL readiness check
 *
 * Prints one line per check and exits 1 if any failed.
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
	const char *dev = argc > 2 && !strcmp(argv[1], "-d") ? argv[2] : "/dev/zynqsdr";

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc > 1 && !strcmp(argv[1], "--pl-up"))
		return pl_up();
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("FAIL open %s: %s\n", dev, strerror(errno));
		return 1;
	}
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
