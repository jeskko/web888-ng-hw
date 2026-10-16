// zynqsdr_probe: print FPGA signature and device DNA via the stock zynqsdr
// driver's read-only ioctls. Freestanding (raw ARM EABI syscalls, no libc),
// so it builds with clang + lld and no ARM sysroot; see Makefile.
//
// The driver allows one opener: stop the server (rc-service sdrd stop) first.
// Note that open() itself clears CFG ctrl (stops DMA), as the server's own
// open does.
//
// SPDX-License-Identifier: GPL-3.0-or-later

typedef unsigned int u32;
typedef unsigned long long u64;

#define GET_DNA       0x80085a03u   // _IOR('Z', 3, u64)
#define GET_SIGNATURE 0x80045a09u   // _IOR('Z', 9, u32)

static long sys3(long n, long a, long b, long c)
{
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  register long r7 __asm__("r7") = n;
  __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
  return r0;
}

#define SYS_exit  1
#define SYS_write 4
#define SYS_open  5
#define SYS_close 6
#define SYS_ioctl 54

static void puts_(const char *s)
{
  long n = 0;
  while (s[n]) n++;
  sys3(SYS_write, 1, (long)s, n);
}

static void hex(u64 v, int digits)
{
  char b[17];
  for (int i = digits - 1; i >= 0; i--, v >>= 4)
    b[i] = "0123456789abcdef"[v & 15];
  b[digits] = 0;
  puts_(b);
}

static int run(void)
{
  long fd = sys3(SYS_open, (long)"/dev/zynqsdr", 2 /* O_RDWR */, 0);
  if (fd < 0) {
    puts_("open /dev/zynqsdr failed (server still running?) errno ");
    hex((u64)-fd, 4);
    puts_("\n");
    return 1;
  }

  u32 sig = 0;
  u64 dna = 0;
  long r1 = sys3(SYS_ioctl, fd, GET_SIGNATURE, (long)&sig);
  long r2 = sys3(SYS_ioctl, fd, GET_DNA, (long)&dna);
  sys3(SYS_close, fd, 0, 0);

  if (r1 < 0 || r2 < 0) {
    puts_("ioctl failed\n");
    return 1;
  }
  puts_("signature 0x"); hex(sig, 8);
  puts_("\ndna       0x"); hex(dna, 16);
  puts_("\n");
  return 0;
}

__attribute__((naked, noreturn)) void _start(void)
{
  __asm__ volatile(
    "bl  %c0\n"
    "mov r7, #1\n"      // SYS_exit, status in r0
    "svc 0\n"
    :: "i"(run));
}
