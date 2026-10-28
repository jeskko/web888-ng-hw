// wdt: drive the Linux watchdog (/dev/watchdog) for tests on a remote
// board, so that a hard hang (e.g. an AXI bus lock-up) resets it instead of
// needing a power cycle. Freestanding (raw ARM EABI syscalls, no libc), so
// it builds with clang + lld and no ARM sysroot; see Makefile.
//
//   wdt info                    identity, options, timeout (opening the
//                               device arms it; disarmed again at once)
//   wdt keep TIMEOUT [SECONDS]  arm with TIMEOUT s and kick every TIMEOUT/4 s;
//                               stop when SECONDS have passed (0: never) or
//                               /tmp/wdt.stop exists, then disarm (magic close)
//   wdt set TIMEOUT             program TIMEOUT, then disarm: the hardware
//                               keeps it in its counter register, stopped
//                               (for chainboot, which starts it itself)
//   wdt hang TIMEOUT            arm, kick once, then stop kicking: the board
//                               resets after TIMEOUT s (simulates a hang)
//
// Killing `keep` with SIGKILL leaves the watchdog armed: the board resets.
// Needs a driver without nowayout (cadence_wdt: nowayout=0) for the disarm.
//
// SPDX-License-Identifier: GPL-3.0-or-later

typedef unsigned int u32;

static long sys3(long n, long a, long b, long c)
{
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  register long r7 __asm__("r7") = n;
  __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
  return r0;
}

#define SYS_exit      1
#define SYS_write     4
#define SYS_open      5
#define SYS_close     6
#define SYS_unlink   10
#define SYS_access   33
#define SYS_ioctl    54
#define SYS_nanosleep 162
#define O_WRONLY 1

// <linux/watchdog.h>, 32-bit ARM
#define WDIOC_GETSUPPORT  0x80285700u // _IOR('W', 0, struct watchdog_info)
#define WDIOC_KEEPALIVE   0x80045705u // _IOR('W', 5, int)
#define WDIOC_SETTIMEOUT  0xc0045706u // _IOWR('W', 6, int)
#define WDIOC_GETTIMEOUT  0x80045707u // _IOR('W', 7, int)

struct watchdog_info {
  u32 options;
  u32 firmware_version;
  unsigned char identity[32];
};

static void out(const char *s)
{
  long n = 0;
  while (s[n]) n++;
  sys3(SYS_write, 1, (long)s, n);
}

static void num(long v)
{
  char b[16];
  int i = 15;
  int neg = v < 0;
  b[i] = 0;
  if (neg) v = -v;
  do { b[--i] = '0' + v % 10; v /= 10; } while (v);
  if (neg) b[--i] = '-';
  out(b + i);
}

static void die(const char *what, long r)
{
  out("wdt: ");
  out(what);
  out(" failed: ");
  num(r);
  out("\n");
  sys3(SYS_exit, 1, 0, 0);
}

static long atoi_(const char *s)
{
  long v = 0;
  while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
  return v;
}

static int eq(const char *a, const char *b)
{
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}

static void sleep_s(long s)
{
  long ts[2] = { s, 0 };
  sys3(SYS_nanosleep, (long)ts, 0, 0);
}

// opening starts the timer: a failure after the open disarms first, or
// the board resets at the old timeout
static void die_open(long fd, const char *what, long r)
{
  sys3(SYS_write, fd, (long)"V", 1);
  sys3(SYS_close, fd, 0, 0);
  out("disarmed\n");
  die(what, r);
}

static long arm(long timeout)
{
  long fd = sys3(SYS_open, (long)"/dev/watchdog", O_WRONLY, 0);
  if (fd < 0) die("open /dev/watchdog", fd);
  int t = timeout;
  long r = sys3(SYS_ioctl, fd, WDIOC_SETTIMEOUT, (long)&t);
  if (r < 0) die_open(fd, "WDIOC_SETTIMEOUT", r);
  r = sys3(SYS_ioctl, fd, WDIOC_GETTIMEOUT, (long)&t);
  if (r < 0) die_open(fd, "WDIOC_GETTIMEOUT", r);
  out("armed, timeout ");
  num(t);
  out(" s\n");
  return fd;
}

static void disarm(long fd)
{
  // magic close: 'V' then close stops the timer (without nowayout)
  sys3(SYS_write, fd, (long)"V", 1);
  sys3(SYS_close, fd, 0, 0);
  out("disarmed\n");
}

void _start_c(long *sp)
{
  int argc = (int)sp[0];
  char **argv = (char **)(sp + 1);
  if (argc < 2) {
    out("usage: wdt info | keep TIMEOUT [SECONDS] | set TIMEOUT | hang TIMEOUT\n");
    sys3(SYS_exit, 2, 0, 0);
  }
  if (eq(argv[1], "info")) {
    long fd = sys3(SYS_open, (long)"/dev/watchdog", O_WRONLY, 0);
    if (fd < 0) die("open /dev/watchdog", fd);
    struct watchdog_info wi;
    int t = 0;
    if (sys3(SYS_ioctl, fd, WDIOC_GETSUPPORT, (long)&wi) == 0) {
      wi.identity[31] = 0;
      out("identity: ");
      out((const char *)wi.identity);
      out("\noptions: 0x");
      for (int s = 28; s >= 0; s -= 4) {
        char c[2] = { "0123456789abcdef"[(wi.options >> s) & 15], 0 };
        out(c);
      }
      out(" (0x100 = magic close)\n");
    }
    if (sys3(SYS_ioctl, fd, WDIOC_GETTIMEOUT, (long)&t) == 0) {
      out("timeout: ");
      num(t);
      out(" s\n");
    }
    disarm(fd);
  } else if (eq(argv[1], "keep") && argc >= 3) {
    long timeout = atoi_(argv[2]);
    long secs = argc >= 4 ? atoi_(argv[3]) : 0;
    long step = timeout / 4 > 0 ? timeout / 4 : 1;
    sys3(SYS_unlink, (long)"/tmp/wdt.stop", 0, 0); // a stale one
    long fd = arm(timeout);
    for (long t = 0; secs == 0 || t < secs; t += step) {
      if (sys3(SYS_access, (long)"/tmp/wdt.stop", 0, 0) == 0) {
        out("/tmp/wdt.stop found\n");
        break;
      }
      int dummy = 0;
      sys3(SYS_ioctl, fd, WDIOC_KEEPALIVE, (long)&dummy);
      sleep_s(step);
    }
    disarm(fd);
  } else if (eq(argv[1], "set") && argc >= 3) {
    disarm(arm(atoi_(argv[2])));
  } else if (eq(argv[1], "hang") && argc >= 3) {
    long timeout = atoi_(argv[2]);
    arm(timeout);
    out("not kicking any more: reset expected in ");
    num(timeout);
    out(" s\n");
    for (long t = timeout; ; t--) {
      num(t);
      out(" ");
      sleep_s(1);
    }
  } else {
    out("wdt: unknown command\n");
    sys3(SYS_exit, 2, 0, 0);
  }
  sys3(SYS_exit, 0, 0, 0);
}

// Entry: pass the initial stack pointer (argc, argv) to _start_c.
__asm__(".global _start\n_start:\n mov r0, sp\n bl _start_c\n");
