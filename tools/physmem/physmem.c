// physmem: read and write physical memory through /dev/mem, for the stock
// firmware, which has no devmem.
//   physmem r32 ADDR          print one word
//   physmem w32 ADDR VALUE    write one word, print it read back
//   physmem dump ADDR LEN     raw bytes to stdout (e.g. the ramoops region
//                             a chain-loaded kernel left before a reset)
// Numbers in hex (0x optional). Writes to the PL need a bitstream that
// answers on the bus. Freestanding (raw ARM EABI syscalls, no libc).
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
#define SYS_munmap 91
#define SYS_mmap2  192
#define O_RDWR     2
#define O_SYNC     04010000
#define PROT_READ  1
#define PROT_WRITE 2
#define MAP_SHARED 1

static void wr(const void *s, long n) { sys6(SYS_write, 1, (long)s, n, 0, 0, 0); }

static void out(const char *s)
{
  long n = 0;
  while (s[n]) n++;
  wr(s, n);
}

static void die(const char *s) { out(s); sys6(SYS_exit, 1, 0, 0, 0, 0, 0); }

static void hex(u32 v)
{
  char b[11] = "0x00000000";
  for (int i = 0; i < 8; i++) b[9 - i] = "0123456789abcdef"[(v >> (4 * i)) & 15];
  out(b);
}

static int eq(const char *a, const char *b)
{
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}

static u32 num(const char *s)
{
  u32 v = 0;
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
  if (!*s) die("bad number\n");
  for (; *s; s++) {
    int d = *s >= '0' && *s <= '9' ? *s - '0' : (*s | 32) >= 'a' && (*s | 32) <= 'f' ? (*s | 32) - 'a' + 10 : -1;
    if (d < 0) die("bad number\n");
    v = v << 4 | d;
  }
  return v;
}

static volatile u32 *map(long fd, u32 page, u32 len)
{
  volatile u32 *p = (volatile u32 *)sys6(SYS_mmap2, 0, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page >> 12);
  if ((unsigned long)p > 0xfffff000ul) die("mmap failed\n");
  return p;
}

void _start_c(long *sp)
{
  int argc = (int)sp[0];
  char **argv = (char **)(sp + 1);
  if (argc < 3) die("usage: physmem r32 ADDR | w32 ADDR VALUE | dump ADDR LEN\n");
  long fd = sys6(SYS_open, (long)"/dev/mem", O_RDWR | O_SYNC, 0, 0, 0, 0);
  if (fd < 0) die("open /dev/mem failed\n");
  u32 a = num(argv[2]);
  if (eq(argv[1], "r32") || (eq(argv[1], "w32") && argc == 4)) {
    if (a & 3) die("unaligned\n");
    volatile u32 *p = map(fd, a & ~0xfffu, 0x1000);
    if (argc == 4) p[(a & 0xfff) / 4] = num(argv[3]);
    hex(a); out(" = "); hex(p[(a & 0xfff) / 4]); out("\n");
  } else if (eq(argv[1], "dump") && argc == 4) {
    u32 end = a + num(argv[3]);
    // a page at a time, so a large region needs no large mapping
    for (u32 pa = a; pa < end;) {
      u32 page = pa & ~0xfffu, n = (end - page < 0x1000 ? end : page + 0x1000) - pa;
      volatile u32 *p = map(fd, page, 0x1000);
      wr((const char *)p + (pa & 0xfff), n);
      sys6(SYS_munmap, (long)p, 0x1000, 0, 0, 0, 0);
      pa += n;
    }
  } else {
    die("usage: physmem r32 ADDR | w32 ADDR VALUE | dump ADDR LEN\n");
  }
  sys6(SYS_exit, 0, 0, 0, 0, 0, 0);
}

// Entry: pass the initial stack pointer (argc, argv) to _start_c.
__asm__(".global _start\n_start:\n mov r0, sp\n bl _start_c\n");
