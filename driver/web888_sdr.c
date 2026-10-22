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
 * that keeps frame alignment, and ZSDR_GET_STATS.
 *
 * Copyright (c) 2026 web888-ng contributors
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/math64.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
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

#define CFG_SIZE	0xa0
#define STS_SIZE	0x40	/* stock maps 0x18; 0x18.. are extensions */
#define PPS_SIZE	0x1000

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

#define SIG_OPEN	0x0e5d

#define BURST		128
#define RING_BURSTS	0xff8		/* as stock: 0x7fc00 bytes */
#define RING_BYTES	(RING_BURSTS * BURST)
#define NWF		2
#define MAX_RX		13

/* stream indices */
#define S_RX		0
#define S_WF(n)		(1 + (n))
#define NSTREAMS	3

/* GPIOs, in the order of the DT `gpios` property */
enum { G_MODE, G_ATT_CLK, G_ATT_LATCH, G_ATT_DATA, G_CLK, NGPIOS };

struct zsdr_stream {
	void *buf;
	dma_addr_t dma;
	u32 rd;			/* read offset in the ring, bytes */
	u64 rd_abs;		/* bytes consumed since start (RX, ext) */
	int irq;		/* "burst done" interrupt, or < 0 */
	bool armed;		/* irq enabled, waiting for a burst */
};

struct zsdr {
	struct device *dev;
	void __iomem *cfg;
	void __iomem *sts;
	void __iomem *pps;
	struct gpio_desc *gpio[NGPIOS];
	struct miscdevice misc;

	u32 signature;
	bool ext;		/* open bitstream: extension registers */
	u16 ctrl;		/* shadow of CFG control (only this driver writes it) */
	unsigned int nrx;

	struct mutex lock;	/* ioctls; one opener at a time */
	atomic_t opened;
	spinlock_t irq_lock;
	wait_queue_head_t wq;
	struct zsdr_stream s[NSTREAMS];
	int pps_irq;
	bool pps_armed;

	u32 rx_overruns;
	u64 rx_overrun_bytes;
};

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
	default:
		return sts_r32(z, STS_PTR2PPS) & 0xffff;
	}
}

static u16 ctrl_bit(int i)
{
	return i == S_RX ? CTRL_RX : CTRL_WF(i - 1);
}

static bool running(struct zsdr *z, int i)
{
	return z->ctrl & ctrl_bit(i);
}

/* bytes of new data in stream i (ring position only) */
static u32 avail(struct zsdr *z, int i)
{
	u32 hw = (hw_ptr(z, i) % RING_BURSTS) * BURST;

	return (hw + RING_BYTES - z->s[i].rd) % RING_BYTES;
}

static bool data_ready(struct zsdr *z)
{
	int i;

	for (i = 0; i < NSTREAMS; i++)
		if (running(z, i) && avail(z, i))
			return true;
	return false;
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
}

/*
 * RX with the open bitstream: STS 0x38 counts completed bursts since RX
 * start without wrapping. It gives the bytes available with one register
 * read, and a ring lap is visible: then skip to the newest half ring, on
 * a frame boundary, and count the loss.
 */
static u32 rx_avail_ext(struct zsdr *z)
{
	struct zsdr_stream *s = &z->s[S_RX];
	u64 hw_abs = (u64)sts_r32(z, STS_RX_BURSTS) * BURST;
	u32 fb = 8 * z->nrx;
	u64 to;

	if (hw_abs < s->rd_abs)
		return 0;		/* restart not visible yet */
	if (hw_abs - s->rd_abs > RING_BYTES - BURST) {
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
		chunk = min(n - done, RING_BYTES - s->rd);
		dma_sync_single_for_cpu(z->dev, s->dma + s->rd, chunk,
					DMA_FROM_DEVICE);
		if (copy_to_user(dst + done, s->buf + s->rd, chunk))
			return -EFAULT;
		s->rd = (s->rd + chunk) % RING_BYTES;
		s->rd_abs += chunk;
		done += chunk;
	}
	return done;
}

static void stream_program(struct zsdr *z, int i)
{
	struct zsdr_stream *s = &z->s[i];

	if (i == S_RX) {
		cfg_w32(z, CFG_RX_ADDR, s->dma);
		cfg_w16(z, CFG_RX_LEN, RING_BURSTS - 1);
	} else {
		cfg_w32(z, CFG_WF_ADDR(i - 1), s->dma);
		cfg_w16(z, CFG_WF_LEN(i - 1), RING_BURSTS - 1);
	}
	stream_reset(z, i);
}

static void stop_all(struct zsdr *z)
{
	ctrl_write(z, 0);
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

/* enable the interrupts of the running streams until the next burst */
static void arm_irqs(struct zsdr *z, bool pps)
{
	unsigned long fl;
	int i;

	spin_lock_irqsave(&z->irq_lock, fl);
	for (i = 0; i < NSTREAMS; i++) {
		struct zsdr_stream *s = &z->s[i];

		if (s->irq >= 0 && !s->armed && running(z, i)) {
			s->armed = true;
			enable_irq(s->irq);
		}
	}
	if (pps && z->pps_irq >= 0 && !z->pps_armed) {
		z->pps_armed = true;
		enable_irq(z->pps_irq);
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

static int zsdr_open(struct inode *inode, struct file *f)
{
	struct zsdr *z = to_zsdr(f);

	if (atomic_cmpxchg(&z->opened, 0, 1))
		return -EBUSY;
	mutex_lock(&z->lock);
	stop_all(z);		/* as stock: open stops all streams */
	mutex_unlock(&z->lock);
	return 0;
}

static int zsdr_release(struct inode *inode, struct file *f)
{
	struct zsdr *z = to_zsdr(f);

	mutex_lock(&z->lock);
	stop_all(z);
	disarm_irqs(z);
	mutex_unlock(&z->lock);
	atomic_set(&z->opened, 0);
	return 0;
}

static __poll_t zsdr_poll(struct file *f, poll_table *wait)
{
	struct zsdr *z = to_zsdr(f);
	__poll_t mask = 0;

	poll_wait(f, &z->wq, wait);
	mutex_lock(&z->lock);
	if (data_ready(z))
		mask |= EPOLLIN | EPOLLRDNORM;
	if ((z->ctrl & CTRL_PPS) && pps_count(z))
		mask |= EPOLLPRI;
	if (!mask)
		arm_irqs(z, z->ctrl & CTRL_PPS);
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
	st->build_id = sts_r32(z, STS_BUILD);
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

static long zsdr_ioctl_locked(struct zsdr *z, unsigned int cmd,
			      unsigned long arg)
{
	void __user *up = (void __user *)arg;
	long r;

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
	r = zsdr_ioctl_locked(z, cmd, arg);
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

	return sysfs_emit(buf, "0x%08x\n", z->signature);
}
static DEVICE_ATTR_RO(signature);

static ssize_t bitstream_show(struct device *dev, struct device_attribute *a,
			      char *buf)
{
	struct zsdr *z = dev_get_drvdata(dev);

	if (!z->ext)
		return sysfs_emit(buf, "stock\n");
	return sysfs_emit(buf, "web888-ng %08x\n", sts_r32(z, STS_BUILD));
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
				resource_size_t fallback, resource_size_t size)
{
	struct resource *r = platform_get_resource(pdev, IORESOURCE_MEM, idx);

	if (r)
		return devm_ioremap_resource(&pdev->dev, r);
	/* vendor DT: node without reg, fixed addresses */
	return devm_ioremap(&pdev->dev, fallback, size) ?: IOMEM_ERR_PTR(-ENOMEM);
}

static int zsdr_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct zsdr *z;
	int i, ret;

	z = devm_kzalloc(dev, sizeof(*z), GFP_KERNEL);
	if (!z)
		return -ENOMEM;
	z->dev = dev;
	mutex_init(&z->lock);
	spin_lock_init(&z->irq_lock);
	init_waitqueue_head(&z->wq);
	platform_set_drvdata(pdev, z);

	z->cfg = map_window(pdev, 0, CFG_PHYS, CFG_SIZE);
	if (IS_ERR(z->cfg))
		return PTR_ERR(z->cfg);
	z->sts = map_window(pdev, 1, STS_PHYS, STS_SIZE);
	if (IS_ERR(z->sts))
		return PTR_ERR(z->sts);
	z->pps = map_window(pdev, 2, PPS_PHYS, PPS_SIZE);
	if (IS_ERR(z->pps))
		return PTR_ERR(z->pps);

	z->signature = sts_r32(z, STS_SIG);
	z->ext = (z->signature >> 16) == SIG_OPEN;
	z->nrx = z->signature & 0xf;
	if (!z->nrx || z->nrx > MAX_RX)
		return dev_err_probe(dev, -ENODEV,
				     "no SDR logic (signature 0x%08x)\n",
				     z->signature);

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
	for (i = 0; i < NSTREAMS; i++) {
		struct zsdr_stream *s = &z->s[i];

		s->buf = dma_alloc_noncoherent(dev, RING_BYTES, &s->dma,
					       DMA_FROM_DEVICE, GFP_KERNEL);
		if (!s->buf) {
			ret = -ENOMEM;
			goto free;
		}
		s->irq = -ENXIO;
	}

	/* IRQ_F2P 0..3: RX, WF0, WF1 burst done, PPS edge */
	z->pps_irq = -ENXIO;
	for (i = 0; i < 4; i++) {
		int irq = platform_get_irq_optional(pdev, i);

		if (irq < 0)
			continue;
		ret = devm_request_irq(dev, irq, burst_irq, IRQF_NO_AUTOEN,
				       DRV_NAME, z);
		if (ret)
			goto free;
		if (i < NSTREAMS)
			z->s[i].irq = irq;
		else
			z->pps_irq = irq;
	}

	stop_all(z);

	z->misc.minor = MISC_DYNAMIC_MINOR;
	z->misc.name = "zynqsdr";	/* the stock device name */
	z->misc.fops = &zsdr_fops;
	z->misc.parent = dev;
	ret = misc_register(&z->misc);
	if (ret)
		goto free;

	dev_info(dev, "signature 0x%08x (%s bitstream), %u RX channels%s\n",
		 z->signature, z->ext ? "open" : "stock", z->nrx,
		 z->s[S_RX].irq < 0 ? ", no interrupts (poll() unavailable)" : "");
	return 0;

free:
	for (i = 0; i < NSTREAMS; i++)
		if (z->s[i].buf)
			dma_free_noncoherent(dev, RING_BYTES, z->s[i].buf,
					     z->s[i].dma, DMA_FROM_DEVICE);
	return ret;
}

static void zsdr_remove(struct platform_device *pdev)
{
	struct zsdr *z = platform_get_drvdata(pdev);
	int i;

	misc_deregister(&z->misc);
	stop_all(z);
	/* let outstanding bursts drain before the buffers go away */
	msleep(10);
	for (i = 0; i < NSTREAMS; i++)
		dma_free_noncoherent(z->dev, RING_BYTES, z->s[i].buf,
				     z->s[i].dma, DMA_FROM_DEVICE);
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
