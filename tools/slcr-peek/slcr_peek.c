// slcr_peek: print a few Zynq SLCR registers (PS side, read-only) that say
// whether the PL can work: the PL resets, level shifters and PL clock 0.
// Reading the SLCR never touches the PL, so it is safe on a running board.
// Freestanding (raw ARM EABI syscalls, no libc); see Makefile.
//
// SPDX-License-Identifier: GPL-3.0-or-later

typedef unsigned int u32;

static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  register long r3 __asm__("r3") = d;
  register long r4 __asm__("r4") = e;
  register long r5 __asm__("r5") = f;
  register long r7 __asm__("r7") = n;
  __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5), "r"(r7) : "memory");
  return r0;
}

#define SYS_exit   1
#define SYS_write  4
#define SYS_open   5
#define SYS_mmap2  192
#define O_RDONLY   0
#define O_SYNC     04010000
#define PROT_READ  1
#define MAP_SHARED 1

static void out(const char *s)
{
  long n = 0;
  while (s[n]) n++;
  sys6(SYS_write, 1, (long)s, n, 0, 0, 0);
}

static void hex(u32 v)
{
  char b[11] = "0x00000000";
  for (int i = 0; i < 8; i++) b[9 - i] = "0123456789abcdef"[(v >> (4 * i)) & 15];
  out(b);
}

void _start_c(void)
{
  long fd = sys6(SYS_open, (long)"/dev/mem", O_RDONLY | O_SYNC, 0, 0, 0, 0);
  if (fd < 0) { out("open /dev/mem failed\n"); sys6(SYS_exit, 1, 0, 0, 0, 0, 0); }
  // SLCR at 0xF8000000; mmap2 takes the offset in 4 KiB pages
  volatile u32 *slcr = (volatile u32 *)sys6(SYS_mmap2, 0, 0x1000, PROT_READ, MAP_SHARED, fd, 0xF8000000u >> 12);
  if ((unsigned long)slcr > 0xfffff000ul) { out("mmap failed\n"); sys6(SYS_exit, 1, 0, 0, 0, 0, 0); }
  static const struct { u32 off; const char *name; } regs[] = {
    { 0x170, "FPGA0_CLK_CTRL" },
    { 0x240, "FPGA_RST_CTRL (bit n = FCLK_RESETn_N held in reset)" },
    { 0x900, "LVL_SHFTR_EN (0xf = PS<->PL enabled)" },
  };
  for (unsigned i = 0; i < sizeof regs / sizeof regs[0]; i++) {
    hex(0xF8000000u + regs[i].off);
    out(" = ");
    hex(slcr[regs[i].off / 4]);
    out("  ");
    out(regs[i].name);
    out("\n");
  }
  sys6(SYS_exit, 0, 0, 0, 0, 0, 0);
}

__asm__(".global _start\n_start:\n bl _start_c\n");
