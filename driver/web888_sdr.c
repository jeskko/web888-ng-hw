// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * web888-sdr: open driver for the Web-888 SDR programmable logic.
 *
 * Drop-in for the stock `zynqsdr` driver: same /dev/zynqsdr ioctl ABI
 * (web888_sdr.h), working with the stock bitstream and the open web888-ng
 * bitstream. Written from web888-ng-hw docs/stock-driver.md and
 * fpga/doc/register-map.md only. There is no device-binding check.
 *
 * Extensions for the open bitstream (signature 0x0E5Dxxxx): poll() with
 * interrupts armed only while a reader waits, RX ring overrun detection
 * that keeps frame alignment, and ZSDR_GET_STATS. With the channelizer
 * bitstream (0x0E5D0010): the bin mask, the bins and power line rings
 * (ZSDR_PFB_*).
 *
 * Copyright (c) 2026 web888-ng contributors
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/kref.h>
#include <linux/math64.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/platform_device.h>
#include <linux/poll.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#include "web888_sdr.h"

#define DRV_NAME	"web888-sdr"

/* PL windows when the DT node has no `reg` (the vendor DT) */
#define CFG_PHYS	0x40000000
#define STS_PHYS	0x41000000
#define PPS_PHYS	0x42000000
#define EV_PHYS		0x43000000	/* write events: the channelizer's mask */

/*
 * Zynq-7000 SLCR, read only here: PS-PL level shifters and fabric resets.
 * A PL access while the PL is unconfigured, being reconfigured or held in
 * reset never completes and hangs the CPU.
 */
#define SLCR_PHYS		0xf8000000
#define SLCR_SIZE		0x1000
#define SLCR_FPGA_RST_CTRL	0x240
#define  FPGA_RST0		BIT(0)	/* FCLK_RESET0_N, the PL logic reset */
#define SLCR_LVL_SHFTR_EN	0x900
#define  LVL_SHFTR_ALL		0xf

#define CFG_SIZE	0xb4	/* stock 0xa0; 0xa0.. the channelizer's */
#define STS_SIZE	0x58	/* stock maps 0x18; 0x18.. are extensions */
#define PPS_SIZE	0x1000
#define EV_SIZE		0x100

/* CFG */
#define CFG_CTRL	0x00
#define  CTRL_RX	BIT(0)
#define  CTRL_WF(n)	BIT(1 + (n))
#define  CTRL_PPS	BIT(7)
#define CFG_R2		0x02
#define CFG_RX_NCO(ch)	(0x04 + 8 * (ch))
#define CFG_WF_NCO(n)	(0x6c + 12 * (n))
#define CFG_WF_DEC(n)	(0x74 + 12 * (n))
#define CFG_GPIO	0x84
#define CFG_RX_ADDR	0x8c
#define CFG_RX_LEN	0x90
#define CFG_WF_ADDR(n)	(0x92 + 6 * (n))
#define CFG_WF_LEN(n)	(0x96 + 6 * (n))
#define CFG_WF_MODE	0x9e
#define CFG_PFB_CTRL	0xa0
#define  PFB_BINS	BIT(0)
#define  PFB_POWER	BIT(1)
#define  PFB_GEN(g)	((g) << 4)
#define CFG_BINS_ADDR	0xa4
#define CFG_BINS_LEN	0xa8
#define CFG_PW_FRAMES	0xaa
#define CFG_PW_ADDR	0xac
#define CFG_PW_LEN	0xb0

/* STS */
#define STS_SIG		0x00
#define STS_PTR01	0x04	/* [15:0] RX, [31:16] WF0 */
#define STS_PTR2PPS	0x08	/* [15:0] WF1, [31:16] PPS FIFO count */
#define STS_DNA_LO	0x0c
#define STS_DNA_HI	0x10
#define STS_BUILD	0x18
#define STS_ADC_OVF	0x1c
#define STS_FLAGS	0x20
#define STS_ADC_PEAK	0x24
#define STS_SAMPLES	0x28
#define STS_RX_FRAMES	0x30
#define STS_RX_DROPS	0x34
#define STS_RX_BURSTS	0x38
#define STS_WF_BURSTS	0x3c
#define STS_PFB_PTRS	0x40	/* [15:0] bins, [31:16] power */
#define STS_PFB_FLAGS	0x44
#define STS_BINS_FRAMES	0x48
#define STS_BINS_DROPS	0x4c
#define STS_PW_CHUNKS	0x50
#define STS_PW_DROPS	0x54

#define SIG_OPEN	0x0e5d
#define SIG_PFB(sig)	(((sig) >> 4) & 0xf)	/* 1: the channelizer build */

#define BURST		128
#define RING_BURSTS	0xff8		/* as stock: 0x7fc00 bytes */
#define RING_BYTES	(RING_BURSTS * BURST)
#define NWF		2
#define MAX_RX		13

/* the channelizer's rings: 2 MB of bins (65 ms with 64 selected), 1 MB
 * of power lines (~30 lines) */
#define BINS_BURSTS	0x4000
#define PW_BURSTS	0x2000
#define PFB_NBINS	2048
#define PFB_MAX_SEL	64

/* stream indices */
#define S_RX		0
#define S_WF(n)		(1 + (n))
#define S_BINS		3
#define S_PW		4
#define NSTREAMS	5
#define NIRQS		4	/* IRQ_F2P 0..3 */

/* GPIOs, in the order of the DT `gpios` property */
enum { G_MODE, G_ATT_CLK, G_ATT_LATCH, G_ATT_DATA, G_CLK, NGPIOS };

struct zsdr_stream {
	void *buf;
	dma_addr_t dma;
	u32 bursts;		/* ring length */
	u32 bytes;
	u32 rd;			/* read offset in the ring, bytes */
	u64 rd_abs;		/* bytes consumed since start (RX, ext) */
	u32 hw_last;		/* last STS 0x38 value (RX, ext) */
	u32 hw_wraps;		/* its wraps since start */
	int irq;		/* "burst done" interrupt, or < 0 (set at open) */
	bool armed;		/* irq enabled, waiting for a burst */
};

/*
 * Lifetime: the probe holds one reference and each open file one more, so
 * an unbind while the device is open leaves this structure (but not the
 * DMA buffers or the register windows) to the last release.
 */
struct zsdr {
	struct kref ref;
	struct device *dev;
	void __iomem *slcr;	/* NULL: not a Zynq-7000, no PL check */
	void __iomem *cfg;
	void __iomem *sts;
	void __iomem *pps;
	void __iomem *ev;
	resource_size_t cfg_len, sts_len;	/* as mapped (a DT may give less) */
	struct gpio_desc *gpio[NGPIOS];
	struct miscdevice misc;

	bool gone;		/* unbound; under lock */
	u32 signature;		/* read at open; 0 before the first one */
	u32 build_id;		/* STS 0x18 at open (ext) */
	bool ext;		/* open bitstream: extension registers */
	bool pfb;		/* the channelizer build */
	u16 ctrl;		/* shadow of CFG control (only this driver writes it) */
	u16 pfb_ctrl;		/* and of CFG 0xa0 */
	unsigned int nrx;
	int irqs[NIRQS];	/* IRQ_F2P 0..3, or < 0 */

	struct mutex lock;	/* ioctls, open/release, remove */
	atomic_t opened;
	spinlock_t irq_lock;
	wait_queue_head_t wq;
	struct zsdr_stream s[NSTREAMS];
	int pps_irq;
	bool pps_armed;

	u32 rx_overruns;
	u64 rx_overrun_bytes;
};

static bool pl_check = true;
module_param(pl_check, bool, 0644);
MODULE_PARM_DESC(pl_check,
		 "refuse open unless the SLCR shows the PL out of reset with level shifters on (default 1)");

static void zsdr_free(struct kref *ref)
{
	kfree(container_of(ref, struct zsdr, ref));
}

/* ------------------------------------------------------------ registers */

static u16 cfg_r16(struct zsdr *z, u32 off)
{
	return readw(z->cfg + off);
}

static void cfg_w16(struct zsdr *z, u32 off, u16 v)
{
	writew(v, z->cfg + off);
}

static void cfg_w32(struct zsdr *z, u32 off, u32 v)
{
	if (off & 3) {
		/* 0x92: unaligned word; the PL accepts halfword strobes */
		writew(v & 0xffff, z->cfg + off);
		writew(v >> 16, z->cfg + off + 2);
	} else {
		writel(v, z->cfg + off);
	}
}

static void cfg_w64(struct zsdr *z, u32 off, u64 v)
{
	writel(lower_32_bits(v), z->cfg + off);
	writel(upper_32_bits(v), z->cfg + off + 4);
}

static u32 sts_r32(struct zsdr *z, u32 off)
{
	return readl(z->sts + off);
}

/*
 * Control register writes go through a shadow copy: each register access
 * is an AXI transaction (and a costly exit in the emulator), and reads on
 * the hot read path add up.
 */
static void ctrl_write(struct zsdr *z, u16 v)
{
	z->ctrl = v;
	cfg_w16(z, CFG_CTRL, v);
}

static void ctrl_clear(struct zsdr *z, u16 bits)
{
	ctrl_write(z, z->ctrl & ~bits);
}

static void ctrl_set(struct zsdr *z, u16 bits)
{
	ctrl_write(z, z->ctrl | bits);
}

/* hardware write pointer of stream i, in bursts */
static u32 hw_ptr(struct zsdr *z, int i)
{
	switch (i) {
	case S_RX:
		return sts_r32(z, STS_PTR01) & 0xffff;
	case S_WF(0):
		return sts_r32(z, STS_PTR01) >> 16;
	case S_BINS:
		return sts_r32(z, STS_PFB_PTRS) & 0xffff;
	case S_PW:
		return sts_r32(z, STS_PFB_PTRS) >> 16;
	default:
		return sts_r32(z, STS_PTR2PPS) & 0xffff;
	}
}

static bool running(struct zsdr *z, int i)
{
	switch (i) {
	case S_RX:
		return z->ctrl & CTRL_RX;
	case S_BINS:
		return z->pfb_ctrl & PFB_BINS;
	case S_PW:
		return z->pfb_ctrl & PFB_POWER;
	default:
		return z->ctrl & CTRL_WF(i - 1);
	}
}

/* bytes of new data in stream i (ring position only) */
static u32 avail(struct zsdr *z, int i)
{
	struct zsdr_stream *s = &z->s[i];
	u32 hw = (hw_ptr(z, i) % s->bursts) * BURST;

	return (hw + s->bytes - s->rd) % s->bytes;
}

static u32 pps_count(struct zsdr *z)
{
	return sts_r32(z, STS_PTR2PPS) >> 16;
}

/* --------------------------------------------------------------- streams */

static void stream_reset(struct zsdr *z, int i)
{
	z->s[i].rd = 0;
	z->s[i].rd_abs = 0;
	z->s[i].hw_last = 0;
	z->s[i].hw_wraps = 0;
}

/*
 * Bytes the reader may fall behind before RX skips ahead: a copy of a
 * large read takes milliseconds, and the PL must not overwrite its start
 * meanwhile (~7 ms at 96 kS/s with 12 channels).
 */
#define RX_MARGIN	(RING_BYTES / 8)

/*
 * RX with the open bitstream: STS 0x38 counts completed bursts since RX
 * start, so a ring lap is visible. Extended to 64 bits here: the 32-bit
 * count wraps after 512 GiB (~17 h at 96 kS/s, 12 channels); every read
 * sees it at least once per wrap. With the reader too far behind, skip to
 * the newest half ring on a frame boundary and count the loss.
 */
static u32 rx_avail_ext(struct zsdr *z)
{
	struct zsdr_stream *s = &z->s[S_RX];
	u32 raw = sts_r32(z, STS_RX_BURSTS);
	u32 fb = 8 * z->nrx;
	u64 hw_abs, to;

	if (raw < s->hw_last)
		s->hw_wraps++;
	s->hw_last = raw;
	hw_abs = ((u64)s->hw_wraps << 32 | raw) * BURST;
	if (hw_abs < s->rd_abs)
		return 0;		/* restart not visible yet */
	if (hw_abs - s->rd_abs > RING_BYTES - RX_MARGIN) {
		to = hw_abs - RING_BYTES / 2;
		to = DIV_ROUND_UP_ULL(to, fb) * fb;
		z->rx_overruns++;
		z->rx_overrun_bytes += to - s->rd_abs;
		s->rd_abs = to;
		s->rd = do_div(to, RING_BYTES);
	}
	return hw_abs - s->rd_abs;
}

/*
 * The restart (and the clearing of STS 0x38) happens once outstanding
 * bursts have drained. Wait for it, so that the first read doesn't take
 * the old count for a ring lap.
 */
static void rx_wait_restart(struct zsdr *z)
{
	int t;

	for (t = 0; t < 100; t++) {
		if (sts_r32(z, STS_RX_BURSTS) < RING_BURSTS / 2)
			return;
		udelay(10);
	}
	dev_warn(z->dev, "RX restart not seen within 1 ms\n");
}

/* copy up to len bytes of stream i to user memory; returns bytes or -err */
static long stream_read(struct zsdr *z, int i, u32 uaddr, u32 len)
{
	struct zsdr_stream *s = &z->s[i];
	void __user *dst = (void __user *)(uintptr_t)uaddr;
	u32 n, chunk, done = 0;

	if (!running(z, i))
		return -EINVAL;
	if (i == S_RX && z->ext)
		n = min(rx_avail_ext(z), len);
	else
		n = min(avail(z, i), len);
	while (done < n) {
		chunk = min(n - done, s->bytes - s->rd);
		dma_sync_single_for_cpu(z->dev, s->dma + s->rd, chunk,
					DMA_FROM_DEVICE);
		if (copy_to_user(dst + done, s->buf + s->rd, chunk))
			return -EFAULT;
		s->rd = (s->rd + chunk) % s->bytes;
		s->rd_abs += chunk;
		done += chunk;
	}
	return done;
}

static void stream_program(struct zsdr *z, int i)
{
	struct zsdr_stream *s = &z->s[i];

	switch (i) {
	case S_RX:
		cfg_w32(z, CFG_RX_ADDR, s->dma);
		cfg_w16(z, CFG_RX_LEN, s->bursts - 1);
		break;
	case S_BINS:
		cfg_w32(z, CFG_BINS_ADDR, s->dma);
		cfg_w16(z, CFG_BINS_LEN, s->bursts - 1);
		break;
	case S_PW:
		cfg_w32(z, CFG_PW_ADDR, s->dma);
		cfg_w16(z, CFG_PW_LEN, s->bursts - 1);
		break;
	default:
		cfg_w32(z, CFG_WF_ADDR(i - 1), s->dma);
		cfg_w16(z, CFG_WF_LEN(i - 1), s->bursts - 1);
	}
	stream_reset(z, i);
}

static void pfb_ctrl_write(struct zsdr *z, u16 v)
{
	z->pfb_ctrl = v;
	cfg_w16(z, CFG_PFB_CTRL, v);
}

static void stop_all(struct zsdr *z)
{
	ctrl_write(z, 0);
	if (z->pfb)
		pfb_ctrl_write(z, 0);
}

/* --------------------------------------------------------------- GPIOs */

static void gpio_raw(struct zsdr *z, int g, int v)
{
	/*
	 * Raw levels on purpose: the vendor DT marks these GPIOs active-low,
	 * but the stock driver drives them with the legacy (raw) GPIO API.
	 */
	if (z->gpio[g])
		gpiod_set_raw_value_cansleep(z->gpio[g], v);
}

static int ad8370_set(struct zsdr *z, u32 code)
{
	int b;

	if (!z->gpio[G_ATT_CLK] || !z->gpio[G_ATT_LATCH] || !z->gpio[G_ATT_DATA])
		return -ENODEV;
	gpio_raw(z, G_ATT_LATCH, 0);
	gpio_raw(z, G_ATT_CLK, 0);
	for (b = 7; b >= 0; b--) {
		gpio_raw(z, G_ATT_DATA, (code >> b) & 1);
		udelay(1);
		gpio_raw(z, G_ATT_CLK, 1);
		udelay(1);
		gpio_raw(z, G_ATT_CLK, 0);
	}
	udelay(1);
	gpio_raw(z, G_ATT_LATCH, 1);
	return 0;
}

/* ------------------------------------------------------------ interrupts */

static irqreturn_t burst_irq(int irq, void *data)
{
	struct zsdr *z = data;
	unsigned long fl;
	int i;

	spin_lock_irqsave(&z->irq_lock, fl);
	for (i = 0; i < NSTREAMS; i++) {
		if (z->s[i].irq == irq && z->s[i].armed) {
			disable_irq_nosync(irq);
			z->s[i].armed = false;
		}
	}
	if (z->pps_irq == irq && z->pps_armed) {
		disable_irq_nosync(irq);
		z->pps_armed = false;
	}
	spin_unlock_irqrestore(&z->irq_lock, fl);
	wake_up_interruptible(&z->wq);
	return IRQ_HANDLED;
}

/* enable the stream (or PPS) interrupt until its next event */
static void arm_irq(struct zsdr *z, int irq, bool *armed)
{
	unsigned long fl;

	if (irq < 0)
		return;
	spin_lock_irqsave(&z->irq_lock, fl);
	if (!*armed) {
		*armed = true;
		enable_irq(irq);
	}
	spin_unlock_irqrestore(&z->irq_lock, fl);
}

static void disarm_irqs(struct zsdr *z)
{
	unsigned long fl;
	int i;

	spin_lock_irqsave(&z->irq_lock, fl);
	for (i = 0; i < NSTREAMS; i++) {
		if (z->s[i].armed) {
			disable_irq_nosync(z->s[i].irq);
			z->s[i].armed = false;
		}
	}
	if (z->pps_armed) {
		disable_irq_nosync(z->pps_irq);
		z->pps_armed = false;
	}
	spin_unlock_irqrestore(&z->irq_lock, fl);
}

/* ----------------------------------------------------------------- fops */

static struct zsdr *to_zsdr(struct file *f)
{
	return container_of(f->private_data, struct zsdr, misc);
}

/*
 * The PL may be unconfigured (no bitstream yet, or being reloaded): check
 * the PS side first, then that the logic answers with a known signature.
 * Nothing touches the PL before this succeeds.
 */
static int pl_attach(struct zsdr *z)
{
	u32 sig;
	bool pfb;
	int i;

	if (z->slcr && pl_check) {
		u32 lvl = readl(z->slcr + SLCR_LVL_SHFTR_EN);
		u32 rst = readl(z->slcr + SLCR_FPGA_RST_CTRL);

		if ((lvl & LVL_SHFTR_ALL) != LVL_SHFTR_ALL || (rst & FPGA_RST0)) {
			dev_warn_ratelimited(z->dev,
				"PL not ready (level shifters 0x%x, fabric resets 0x%x): bitstream not loaded?\n",
				lvl, rst);
			return -ENODEV;
		}
	}

	sig = sts_r32(z, STS_SIG);
	pfb = (sig >> 16) == SIG_OPEN && SIG_PFB(sig) == 1;
	z->nrx = sig & 0xf;
	if (pfb && (z->cfg_len < CFG_SIZE || z->sts_len < STS_SIZE)) {
		dev_warn_ratelimited(z->dev,
			"channelizer bitstream, but the DT maps CFG 0x%llx / STS 0x%llx bytes (needs 0x%x / 0x%x)\n",
			(u64)z->cfg_len, (u64)z->sts_len, CFG_SIZE, STS_SIZE);
		return -ENODEV;
	}
	if (!pfb && (!z->nrx || z->nrx > MAX_RX)) {
		dev_warn_ratelimited(z->dev, "no SDR logic (signature 0x%08x)\n",
				     sig);
		return -ENODEV;
	}
	if (sig != z->signature) {
		if (pfb)
			dev_info(z->dev, "signature 0x%08x (channelizer bitstream)\n",
				 sig);
		else
			dev_info(z->dev, "signature 0x%08x (%s bitstream), %u RX channels\n",
				 sig, (sig >> 16) == SIG_OPEN ? "open" : "stock",
				 z->nrx);
	}
	z->signature = sig;
	z->ext = (sig >> 16) == SIG_OPEN;
	z->pfb = pfb;
	z->build_id = z->ext ? sts_r32(z, STS_BUILD) : 0;

	/* the channelizer's rings use RX's and WF0's interrupt lines */
	for (i = 0; i < NSTREAMS; i++)
		z->s[i].irq = -ENXIO;
	if (pfb) {
		z->s[S_BINS].irq = z->irqs[0];
		z->s[S_PW].irq = z->irqs[1];
	} else {
		for (i = 0; i <= S_WF(1); i++)
			z->s[i].irq = z->irqs[i];
	}
	z->pfb_ctrl = 0;
	stop_all(z);		/* as stock: open stops all streams */
	return 0;
}

static int zsdr_open(struct inode *inode, struct file *f)
{
	struct zsdr *z = to_zsdr(f);
	int ret;

	/* misc_open() holds misc_mtx, so remove() can't have run yet */
	if (atomic_cmpxchg(&z->opened, 0, 1))
		return -EBUSY;
	mutex_lock(&z->lock);
	ret = pl_attach(z);
	mutex_unlock(&z->lock);
	if (ret) {
		atomic_set(&z->opened, 0);
		return ret;
	}
	kref_get(&z->ref);
	return 0;
}

static int zsdr_release(struct inode *inode, struct file *f)
{
	struct zsdr *z = to_zsdr(f);

	mutex_lock(&z->lock);
	if (!z->gone) {
		stop_all(z);
		disarm_irqs(z);
	}
	mutex_unlock(&z->lock);
	atomic_set(&z->opened, 0);
	kref_put(&z->ref, zsdr_free);
	return 0;
}

static __poll_t zsdr_poll(struct file *f, poll_table *wait)
{
	struct zsdr *z = to_zsdr(f);
	__poll_t mask = 0, req;
	int i;

	poll_wait(f, &z->wq, wait);
	mutex_lock(&z->lock);
	if (z->gone) {
		mutex_unlock(&z->lock);
		return EPOLLERR | EPOLLHUP;
	}
	/*
	 * Arm each requested source that has nothing yet, even when another
	 * one is ready: a caller waiting only for POLLPRI must still be woken
	 * by PPS while RX data piles up. Not gated on wait->_qproc: do_poll()
	 * clears it after the first pass, and the re-checks after a wakeup
	 * must re-arm. An arm on the last pass costs one interrupt.
	 */
	req = poll_requested_events(wait);
	for (i = 0; i < NSTREAMS; i++) {
		if (!running(z, i))
			continue;
		if (avail(z, i))
			mask |= EPOLLIN | EPOLLRDNORM;
		else if (req & (EPOLLIN | EPOLLRDNORM))
			arm_irq(z, z->s[i].irq, &z->s[i].armed);
	}
	if (z->ctrl & CTRL_PPS) {
		if (pps_count(z))
			mask |= EPOLLPRI;
		else if (req & EPOLLPRI)
			arm_irq(z, z->pps_irq, &z->pps_armed);
	}
	mutex_unlock(&z->lock);
	return mask;
}

static void fill_stats(struct zsdr *z, struct zsdr_stats *st)
{
	memset(st, 0, sizeof(*st));
	st->size = sizeof(*st);
	st->signature = z->signature;
	st->rx_overruns = z->rx_overruns;
	st->rx_overrun_bytes = z->rx_overrun_bytes;
	if (!z->ext)
		return;
	st->ext = 1;
	st->build_id = z->build_id;
	st->adc_overflows = sts_r32(z, STS_ADC_OVF);
	st->flags = sts_r32(z, STS_FLAGS);
	st->adc_peak = sts_r32(z, STS_ADC_PEAK);
	st->adc_samples = sts_r32(z, STS_SAMPLES) |
			  (u64)sts_r32(z, STS_SAMPLES + 4) << 32;
	st->rx_frames = sts_r32(z, STS_RX_FRAMES);
	st->rx_frames_dropped = sts_r32(z, STS_RX_DROPS);
	st->rx_bursts = sts_r32(z, STS_RX_BURSTS);
	st->wf_bursts = sts_r32(z, STS_WF_BURSTS);
}

/* the channelizer build's ioctls */
static long pfb_ioctl(struct zsdr *z, unsigned int cmd, void __user *up)
{
	switch (cmd) {
	case ZSDR_PFB_INFO: {
		struct zsdr_pfb_info in = {
			.size = sizeof(in),
			.bins = PFB_NBINS,
			.max_selected = PFB_MAX_SEL,
			.bin_hz = 30000,
			.frame_hz = 60000,
			.bins_ring_bytes = z->s[S_BINS].bytes,
			.power_ring_bytes = z->s[S_PW].bytes,
		};

		return copy_to_user(up, &in, sizeof(in)) ? -EFAULT : 0;
	}

	case ZSDR_PFB_SET_MASK: {
		struct zsdr_pfb_mask m;
		unsigned int w;

		if (copy_from_user(&m, up, sizeof(m)))
			return -EFAULT;
		if (m.gen < 1 || m.gen > 15)
			return -EINVAL;
		/* into the bank not in use; the gen request switches banks */
		for (w = 0; w < ARRAY_SIZE(m.mask); w++)
			writel(m.mask[w], z->ev + 4 * w);
		pfb_ctrl_write(z, (z->pfb_ctrl & ~PFB_GEN(0xf)) | PFB_GEN(m.gen));
		return 0;
	}

	case ZSDR_PFB_START: {
		struct zsdr_pfb_start st;
		u16 v = z->pfb_ctrl;

		if (copy_from_user(&st, up, sizeof(st)))
			return -EFAULT;
		if (st.streams & ~(ZSDR_PFB_BINS | ZSDR_PFB_POWER))
			return -EINVAL;
		if ((st.streams & ZSDR_PFB_POWER) &&
		    (!st.power_frames || st.power_frames > 0xffff))
			return -EINVAL;
		if (!(st.streams & ZSDR_PFB_BINS))
			v &= ~PFB_BINS;
		if (!(st.streams & ZSDR_PFB_POWER))
			v &= ~PFB_POWER;
		if (v != z->pfb_ctrl) {
			pfb_ctrl_write(z, v);
			/* a ring restarts once its outstanding bursts drained */
			udelay(100);
		}
		if (st.streams & ZSDR_PFB_POWER)
			cfg_w16(z, CFG_PW_FRAMES, st.power_frames);
		if ((st.streams & ZSDR_PFB_BINS) && !(v & PFB_BINS)) {
			stream_program(z, S_BINS);
			v |= PFB_BINS;
		}
		if ((st.streams & ZSDR_PFB_POWER) && !(v & PFB_POWER)) {
			stream_program(z, S_PW);
			v |= PFB_POWER;
		}
		pfb_ctrl_write(z, v);
		return 0;
	}

	case ZSDR_PFB_READ: {
		struct zsdr_pfb_read rd;
		long r;

		if (copy_from_user(&rd, up, sizeof(rd)))
			return -EFAULT;
		if (rd.stream != ZSDR_PFB_BINS && rd.stream != ZSDR_PFB_POWER)
			return -EINVAL;
		r = stream_read(z, rd.stream == ZSDR_PFB_BINS ? S_BINS : S_PW,
				rd.address, rd.length);
		if (r < 0)
			return r;
		return put_user(r, &((struct zsdr_pfb_read __user *)up)->readed);
	}

	case ZSDR_PFB_STATUS: {
		struct zsdr_pfb_status st = { .size = sizeof(st) };

		st.flags = sts_r32(z, STS_PFB_FLAGS);
		st.gen = st.flags & 0xf;
		st.bins_frames = sts_r32(z, STS_BINS_FRAMES);
		st.bins_dropped = sts_r32(z, STS_BINS_DROPS);
		st.power_chunks = sts_r32(z, STS_PW_CHUNKS);
		st.power_dropped = sts_r32(z, STS_PW_DROPS);
		return copy_to_user(up, &st, sizeof(st)) ? -EFAULT : 0;
	}
	}
	return -ENOTTY;
}

static long zsdr_ioctl_locked(struct zsdr *z, unsigned int cmd,
			      unsigned long arg)
{
	void __user *up = (void __user *)arg;
	long r;

	switch (cmd) {
	case ZSDR_RX_START: case ZSDR_RX_PARAM: case ZSDR_RX_READ:
	case ZSDR_WF_START: case ZSDR_WF_PARAM: case ZSDR_WF_READ:
		if (z->pfb)
			return -EOPNOTSUPP;
		break;
	case ZSDR_PFB_INFO: case ZSDR_PFB_SET_MASK: case ZSDR_PFB_START:
	case ZSDR_PFB_READ: case ZSDR_PFB_STATUS:
		if (!z->pfb)
			return -ENODEV;
		return pfb_ioctl(z, cmd, up);
	}

	switch (cmd) {
	case ZSDR_AD8370_SET:
		return ad8370_set(z, arg & 0xff);

	case ZSDR_MODE_SET:
		gpio_raw(z, G_MODE, !!arg);
		return 0;

	case ZSDR_CLK_SET:
		gpio_raw(z, G_CLK, !!arg);
		return 0;

	case ZSDR_GET_DNA: {
		u64 dna = sts_r32(z, STS_DNA_LO) |
			  (u64)sts_r32(z, STS_DNA_HI) << 32;

		return put_user(dna, (u64 __user *)up);
	}

	case ZSDR_RX_START:
		if (arg < 5 || arg > (z->ext ? 63 : 40))
			return -EINVAL;
		ctrl_clear(z, CTRL_RX);
		cfg_w16(z, CFG_R2, arg);
		stream_program(z, S_RX);
		ctrl_set(z, CTRL_RX);
		if (z->ext)
			rx_wait_restart(z);
		return 0;

	case ZSDR_RX_PARAM: {
		struct zsdr_rx_param p;

		if (copy_from_user(&p, up, sizeof(p)))
			return -EFAULT;
		if (p.channel >= z->nrx)
			return -EINVAL;
		cfg_w64(z, CFG_RX_NCO(p.channel), p.freq);
		return 0;
	}

	case ZSDR_RX_READ: {
		struct zsdr_rx_read rd;

		if (copy_from_user(&rd, up, sizeof(rd)))
			return -EFAULT;
		r = stream_read(z, S_RX, rd.address, rd.length);
		if (r < 0)
			return r;
		rd.readed = r;
		return copy_to_user(up, &rd, sizeof(rd)) ? -EFAULT : 0;
	}

	case ZSDR_SET_GPIO:
		writel(arg, z->cfg + CFG_GPIO);
		return 0;

	case ZSDR_GET_GPIO:
		return put_user(readl(z->cfg + CFG_GPIO), (u32 __user *)up);

	case ZSDR_GET_SIGNATURE:
		return put_user(z->signature, (u32 __user *)up);

	case ZSDR_WF_START: {
		unsigned int n = arg & 0xff;
		u16 mode;

		if (n >= NWF)
			return -EINVAL;
		ctrl_clear(z, CTRL_WF(n));
		stream_program(z, S_WF(n));
		/* mode bit 1 = one-shot; the flag selects continuous */
		mode = cfg_r16(z, CFG_WF_MODE);
		if (arg & ZSDR_WF_READ_CONTINUES)
			mode &= ~BIT(n);
		else
			mode |= BIT(n);
		cfg_w16(z, CFG_WF_MODE, mode);
		ctrl_set(z, CTRL_WF(n));
		return 0;
	}

	case ZSDR_WF_PARAM: {
		struct zsdr_wf_param p;

		if (copy_from_user(&p, up, sizeof(p)))
			return -EFAULT;
		if (p.channel >= NWF || !p.decimate || p.decimate > 8192)
			return -EINVAL;
		cfg_w64(z, CFG_WF_NCO(p.channel), p.freq);
		cfg_w32(z, CFG_WF_DEC(p.channel), p.decimate);
		return 0;
	}

	case ZSDR_WF_READ: {
		struct zsdr_wf_read rd;

		if (copy_from_user(&rd, up, sizeof(rd)))
			return -EFAULT;
		if (rd.channel >= NWF)
			return -EINVAL;
		r = stream_read(z, S_WF(rd.channel), rd.address, rd.length);
		if (r < 0)
			return r;
		rd.readed = r;
		return copy_to_user(up, &rd, sizeof(rd)) ? -EFAULT : 0;
	}

	case ZSDR_PPS_START:
		ctrl_clear(z, CTRL_PPS);
		udelay(50);
		if (arg)
			ctrl_set(z, CTRL_PPS);
		return 0;

	case ZSDR_PPS_READ:
		if (!pps_count(z))
			return -EBUSY;
		return put_user(readl(z->pps), (u32 __user *)up);

	case ZSDR_GET_STATS: {
		struct zsdr_stats st;

		fill_stats(z, &st);
		return copy_to_user(up, &st, sizeof(st)) ? -EFAULT : 0;
	}
	}
	return -ENOTTY;
}

static long zsdr_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct zsdr *z = to_zsdr(f);
	long r;

	mutex_lock(&z->lock);
	r = z->gone ? -ENODEV : zsdr_ioctl_locked(z, cmd, arg);
	mutex_unlock(&z->lock);
	return r;
}

static const struct file_operations zsdr_fops = {
	.owner		= THIS_MODULE,
	.open		= zsdr_open,
	.release	= zsdr_release,
	.unlocked_ioctl	= zsdr_ioctl,
	.poll		= zsdr_poll,
	.llseek		= noop_llseek,
};

/* ---------------------------------------------------------------- sysfs */

static ssize_t signature_show(struct device *dev, struct device_attribute *a,
			      char *buf)
{
	struct zsdr *z = dev_get_drvdata(dev);

	/* cached at open: reading the PL here could hang the CPU */
	if (!z->signature)
		return sysfs_emit(buf, "unknown\n");
	return sysfs_emit(buf, "0x%08x\n", z->signature);
}
static DEVICE_ATTR_RO(signature);

static ssize_t bitstream_show(struct device *dev, struct device_attribute *a,
			      char *buf)
{
	struct zsdr *z = dev_get_drvdata(dev);

	if (!z->signature)
		return sysfs_emit(buf, "unknown\n");
	if (!z->ext)
		return sysfs_emit(buf, "stock\n");
	return sysfs_emit(buf, "web888-ng %08x\n", z->build_id);
}
static DEVICE_ATTR_RO(bitstream);

static struct attribute *zsdr_attrs[] = {
	&dev_attr_signature.attr,
	&dev_attr_bitstream.attr,
	NULL
};
ATTRIBUTE_GROUPS(zsdr);

/* ---------------------------------------------------------------- probe */

static void __iomem *map_window(struct platform_device *pdev, int idx,
				resource_size_t fallback, resource_size_t size,
				resource_size_t *len)
{
	struct resource *r = platform_get_resource(pdev, IORESOURCE_MEM, idx);

	if (r) {
		if (len)
			*len = resource_size(r);
		return devm_ioremap_resource(&pdev->dev, r);
	}
	/* vendor DT: node without reg, fixed addresses */
	if (len)
		*len = size;
	return devm_ioremap(&pdev->dev, fallback, size) ?: IOMEM_ERR_PTR(-ENOMEM);
}

static void zsdr_put(void *data)
{
	struct zsdr *z = data;

	kref_put(&z->ref, zsdr_free);
}

static void zsdr_free_bufs(void *data)
{
	struct zsdr *z = data;
	int i;

	for (i = 0; i < NSTREAMS; i++)
		if (z->s[i].buf)
			dma_free_noncoherent(z->dev, z->s[i].bytes, z->s[i].buf,
					     z->s[i].dma, DMA_FROM_DEVICE);
}

/*
 * No PL register access here: at boot the bitstream is usually not loaded
 * yet. pl_attach() at open does it. The devm actions run in reverse order
 * after remove(): interrupts, then buffers, then the probe's reference.
 */
static int zsdr_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct zsdr *z;
	int i, ret;

	z = kzalloc(sizeof(*z), GFP_KERNEL);
	if (!z)
		return -ENOMEM;
	kref_init(&z->ref);
	ret = devm_add_action_or_reset(dev, zsdr_put, z);
	if (ret)
		return ret;
	z->dev = dev;
	mutex_init(&z->lock);
	spin_lock_init(&z->irq_lock);
	init_waitqueue_head(&z->wq);
	platform_set_drvdata(pdev, z);

	z->cfg = map_window(pdev, 0, CFG_PHYS, CFG_SIZE, &z->cfg_len);
	if (IS_ERR(z->cfg))
		return PTR_ERR(z->cfg);
	z->sts = map_window(pdev, 1, STS_PHYS, STS_SIZE, &z->sts_len);
	if (IS_ERR(z->sts))
		return PTR_ERR(z->sts);
	z->pps = map_window(pdev, 2, PPS_PHYS, PPS_SIZE, NULL);
	if (IS_ERR(z->pps))
		return PTR_ERR(z->pps);
	z->ev = map_window(pdev, 3, EV_PHYS, EV_SIZE, NULL);
	if (IS_ERR(z->ev))
		return PTR_ERR(z->ev);
	if (of_machine_is_compatible("xlnx,zynq-7000")) {
		/* owned by the SLCR syscon: map without requesting it */
		z->slcr = devm_ioremap(dev, SLCR_PHYS, SLCR_SIZE);
		if (!z->slcr)
			return -ENOMEM;
	}

	for (i = 0; i < NGPIOS; i++) {
		z->gpio[i] = devm_gpiod_get_index_optional(dev, NULL, i,
							   GPIOD_ASIS);
		if (IS_ERR(z->gpio[i]))
			return dev_err_probe(dev, PTR_ERR(z->gpio[i]),
					     "gpio %d\n", i);
		if (z->gpio[i]) {
			ret = gpiod_direction_output_raw(z->gpio[i],
					gpiod_get_raw_value_cansleep(z->gpio[i]));
			if (ret)
				return ret;
		}
	}

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return ret;
	ret = devm_add_action(dev, zsdr_free_bufs, z);
	if (ret)
		return ret;
	for (i = 0; i < NSTREAMS; i++) {
		struct zsdr_stream *s = &z->s[i];

		s->bursts = i == S_BINS ? BINS_BURSTS :
			    i == S_PW ? PW_BURSTS : RING_BURSTS;
		s->bytes = s->bursts * BURST;
		s->buf = dma_alloc_noncoherent(dev, s->bytes, &s->dma,
					       DMA_FROM_DEVICE, GFP_KERNEL);
		if (!s->buf)
			return -ENOMEM;
		s->irq = -ENXIO;
	}

	/*
	 * IRQ_F2P 0..3: RX, WF0, WF1 burst done, PPS edge (the channelizer:
	 * bins, power, -, PPS); the streams get theirs at open
	 */
	for (i = 0; i < NIRQS; i++) {
		int irq = platform_get_irq_optional(pdev, i);

		z->irqs[i] = irq;
		if (irq < 0)
			continue;
		ret = devm_request_irq(dev, irq, burst_irq, IRQF_NO_AUTOEN,
				       DRV_NAME, z);
		if (ret)
			return ret;
	}
	z->pps_irq = z->irqs[3];

	z->misc.minor = MISC_DYNAMIC_MINOR;
	z->misc.name = "zynqsdr";	/* the stock device name */
	z->misc.fops = &zsdr_fops;
	z->misc.parent = dev;
	ret = misc_register(&z->misc);
	if (ret)
		return ret;

	dev_info(dev, "registered%s%s\n",
		 z->irqs[0] < 0 ? ", no interrupts (poll() unavailable)" : "",
		 z->slcr && pl_check ? "" : ", no PL readiness check");
	return 0;
}

static void zsdr_remove(struct platform_device *pdev)
{
	struct zsdr *z = platform_get_drvdata(pdev);
	bool was_running;

	misc_deregister(&z->misc);	/* waits out a running misc_open() */
	mutex_lock(&z->lock);
	/* streams run only after a successful open, so the PL is there */
	was_running = z->ctrl || z->pfb_ctrl;
	if (was_running)
		stop_all(z);
	disarm_irqs(z);
	z->gone = true;
	mutex_unlock(&z->lock);
	wake_up_interruptible(&z->wq);
	/* let outstanding bursts drain before the buffers go away */
	if (was_running)
		msleep(10);
}

static const struct of_device_id zsdr_of_match[] = {
	{ .compatible = "web888-ng,sdr" },
	{ .compatible = "rx888,zynqsdr" },	/* vendor device tree */
	{ }
};
MODULE_DEVICE_TABLE(of, zsdr_of_match);

static struct platform_driver zsdr_driver = {
	.probe	= zsdr_probe,
	.remove	= zsdr_remove,
	.driver	= {
		.name		= DRV_NAME,
		.of_match_table	= zsdr_of_match,
		.dev_groups	= zsdr_groups,
	},
};
module_platform_driver(zsdr_driver);

MODULE_DESCRIPTION("Web-888 SDR programmable logic (open driver)");
MODULE_AUTHOR("web888-ng contributors");
MODULE_LICENSE("GPL");
