// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * chainboot: start another kernel from a running one that has no kexec
 * (the Web-888's stock 6.6.110-xilinx; web888-ng-hw docs/os-base.md).
 *
 *   insmod chainboot.ko zimage=PATH dtb=PATH [initrd=PATH] \
 *       restart=0x... prepare=0x... readfile=0x... [go=1]
 *
 * restart, prepare and readfile are the addresses of soft_restart,
 * kernel_restart_prepare and kernel_read_file_from_path_initns
 * (/proc/kallsyms: not exported). The files go to fixed physical places
 * (DTB 0x01f00000, zImage 0x02000000, initrd 0x04000000: the zImage in
 * the first 128 MB, as the decompressor takes RAM to start at its load
 * address rounded down to 128 MB; the kernel unpacks to 0x8000); the DTB's
 * bootargs must say where the initrd is (initrd=0x04000000,SIZE). The
 * other CPUs must be offline (the loader checks: /sys/devices/system/cpu/
 * online reads 0). Without go=1 everything is prepared and
 * checked, then freed: the module load fails with -EAGAIN and the system
 * goes on.
 *
 * With go=1: devices are shut down as for a reboot, and soft_restart
 * (MMU, caches and the L2 off) runs a copy of reloc.S from a page of its
 * own, which copies every page to its place and enters the new kernel.
 * The hardware watchdog is not touched: armed beforehand, it resets the
 * board if the new kernel never takes over.
 */
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kernel.h>
#include <linux/gfp.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/kernel_read_file.h>
#include <asm/memory.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("start another kernel without kexec");

static char *zimage, *dtb, *initrd, *restart, *prepare, *readfile;
static int go;
module_param(zimage, charp, 0);
module_param(dtb, charp, 0);
module_param(initrd, charp, 0);
module_param(restart, charp, 0);
module_param(prepare, charp, 0);
module_param(readfile, charp, 0);
module_param(go, int, 0);

#define DTB_AT    0x01f00000u
#define ZIMAGE_AT 0x02000000u
#define INITRD_AT 0x04000000u
/* the places, with room for each */
#define DTB_MAX    (1u << 20)
#define ZIMAGE_MAX (32u << 20)
#define INITRD_MAX (64u << 20)
/* list words a page */
#define PER_PAGE (PAGE_SIZE / sizeof(u32))

extern char cb_reloc_start[], cb_reloc_end[], cb_reloc_data[];

typedef void (*restart_fn)(unsigned long addr);
typedef void (*prepare_fn)(char *cmd);
typedef ssize_t (*readfile_fn)(const char *path, loff_t offset, void **buf,
			       size_t buf_size, size_t *file_size,
			       enum kernel_read_file_id id);

struct img {
	const char *name;
	u32 at, max;
	void *data;		/* vmalloc, from the file */
	size_t size;
};

/* the pages handed out, and the ones refused (they lie where images go) */
struct pagelist {
	unsigned long *v;
	unsigned int n, cap;
};

static struct img imgs[3];
static struct pagelist used, refused;

static bool in_dest(u32 p, u32 len)
{
	int i;

	for (i = 0; i < 3; i++)
		if (imgs[i].data && p < imgs[i].at + imgs[i].max && imgs[i].at < p + len)
			return true;
	return false;
}

static int keep(struct pagelist *l, unsigned long v)
{
	if (l->n == l->cap) {
		unsigned int cap = l->cap ? 2 * l->cap : 1024;
		unsigned long *nv = kmalloc_array(cap, sizeof(*nv), GFP_KERNEL);

		if (!nv)
			return -ENOMEM;
		if (l->v) {
			memcpy(nv, l->v, l->n * sizeof(*nv));
			kfree(l->v);
		}
		l->v = nv;
		l->cap = cap;
	}
	l->v[l->n++] = v;
	return 0;
}

/* a page outside every destination */
static unsigned long safe_page(void)
{
	for (;;) {
		unsigned long v = __get_free_page(GFP_KERNEL);

		if (!v)
			return 0;
		if (!in_dest(virt_to_phys((void *)v), PAGE_SIZE)) {
			if (keep(&used, v)) {
				free_page(v);
				return 0;
			}
			return v;
		}
		if (keep(&refused, v)) {
			free_page(v);
			return 0;
		}
	}
}

static void free_all(void)
{
	unsigned int i;

	for (i = 0; i < used.n; i++)
		free_page(used.v[i]);
	for (i = 0; i < refused.n; i++)
		free_page(refused.v[i]);
	kfree(used.v);
	kfree(refused.v);
	used = (struct pagelist){};
	refused = (struct pagelist){};
}

static int parse_addr(const char *s, unsigned long *a)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v) || v < PAGE_OFFSET)
		return -EINVAL;
	*a = v;
	return 0;
}

static int __init chainboot_init(void)
{
	unsigned long a_restart, a_prepare, a_readfile, stub;
	u32 *list, *head;
	unsigned int npages = 0, k = 0, i;
	readfile_fn rf;
	int err = -EINVAL;

	if (!zimage || !dtb || parse_addr(restart, &a_restart) ||
	    parse_addr(prepare, &a_prepare) || parse_addr(readfile, &a_readfile)) {
		pr_err("chainboot: zimage, dtb, restart, prepare and readfile are needed\n");
		return -EINVAL;
	}
	rf = (readfile_fn)a_readfile;
	imgs[0] = (struct img){ "zImage", ZIMAGE_AT, ZIMAGE_MAX };
	imgs[1] = (struct img){ "DTB", DTB_AT, DTB_MAX };
	imgs[2] = (struct img){ "initrd", INITRD_AT, INITRD_MAX };
	{
		const char *path[3] = { zimage, dtb, initrd };

		for (i = 0; i < 3; i++) {
			ssize_t n;

			if (!path[i])
				continue;
			n = rf(path[i], 0, &imgs[i].data, imgs[i].max, NULL, READING_UNKNOWN);
			if (n < 0) {
				pr_err("chainboot: %s %s: %zd\n", imgs[i].name, path[i], n);
				imgs[i].data = NULL;
				err = n;
				goto out;
			}
			imgs[i].size = n;
			npages += DIV_ROUND_UP(n, PAGE_SIZE);
			pr_info("chainboot: %s %s, %zd bytes at %#x\n", imgs[i].name, path[i], n, imgs[i].at);
		}
	}

	/* the list, in pages outside the destinations, chained by {1, next} */
	err = -ENOMEM;
	head = list = (u32 *)safe_page();
	if (!list)
		goto out;

	/* every page of every image, copied into a page outside them */
	for (i = 0; i < 3; i++) {
		size_t off;

		if (!imgs[i].data)
			continue;
		for (off = 0; off < imgs[i].size; off += PAGE_SIZE) {
			unsigned long p = safe_page();
			size_t n = min_t(size_t, PAGE_SIZE, imgs[i].size - off);

			if (!p)
				goto out;
			memcpy((void *)p, imgs[i].data + off, n);
			if (n < PAGE_SIZE)
				memset((void *)p + n, 0, PAGE_SIZE - n);
			/* room for this pair, the chain pair and the end */
			if (k >= PER_PAGE - 4) {
				u32 *next = (u32 *)safe_page();

				if (!next)
					goto out;
				list[k++] = 1;
				list[k++] = virt_to_phys(next);
				list = next;
				k = 0;
			}
			list[k++] = imgs[i].at + off;
			list[k++] = virt_to_phys((void *)p);
		}
		vfree(imgs[i].data);
		imgs[i].data = (void *)1; /* still a destination for in_dest */
	}
	list[k] = 0;

	/* the relocation code, in a page of its own */
	stub = safe_page();
	if (!stub)
		goto out;
	memcpy((void *)stub, cb_reloc_start, cb_reloc_end - cb_reloc_start);
	{
		u32 *data = (u32 *)(stub + (cb_reloc_data - cb_reloc_start));

		data[0] = virt_to_phys(head);
		data[1] = ZIMAGE_AT;
		data[2] = DTB_AT;
	}
	pr_info("chainboot: %u pages, %u refused; list at %#x, code at %#x\n",
		npages, refused.n, (u32)virt_to_phys(head), (u32)virt_to_phys((void *)stub));

	if (go != 1) {
		pr_info("chainboot: dry run, nothing started\n");
		err = -EAGAIN;
		goto out;
	}

	pr_emerg("chainboot: shutting down, then starting the new kernel\n");
	((prepare_fn)a_prepare)("chainboot");
	((restart_fn)a_restart)(virt_to_phys((void *)stub));
	return -EIO; /* not reached */

out:
	for (i = 0; i < 3; i++)
		if (imgs[i].data && imgs[i].data != (void *)1)
			vfree(imgs[i].data);
	free_all();
	return err;
}

module_init(chainboot_init);
