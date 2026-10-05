/* HPP lattice gas automaton compiled to WebAssembly.
 * Same model as lga.janet: square lattice, 4 velocities E=1 N=2 W=4 S=8.
 * Collide: 5 (E+W) <-> 10 (N+S). Stream: one cell per step, walls bounce
 * particles back. Freestanding, no libc: build with clang --target=wasm32.
 */
#include <stddef.h>
#include <stdint.h>

typedef uint8_t u8;
typedef uint32_t u32;

/* Wall thickness in cells, enough that streaming never leaves the grid. */
#define WALL 2
#define MAXSIDE 2000
#define MAXN (MAXSIDE * MAXSIDE)

static u8 cur[MAXN];
static u8 nxt[MAXN];
static u8 solid[MAXN];
static u8 *curp = cur;
static u8 *nxtp = nxt;

static int g_w, g_h;
static u32 rng;

static u32 xorshift32(void) {
  u32 x = rng;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return rng = x;
}

/* Uniform [0,1] from the top 24 bits of the generator. */
static double rand01(void) { return (xorshift32() >> 8) / 16777215.0; }

static int on_grid(int v, int size) {
  /* Scale a length given for a 250 cell grid to `size` cells. */
  return (int)(((double)v * (double)size) / 250.0 + 0.5);
}

void init(int w_, int h_, unsigned seed, double gas, double burst) {
  size_t n, i;
  int x, y, x0, x1, y0, y1;

  if (w_ < 1 || h_ < 1 || w_ > MAXSIDE || h_ > MAXSIDE)
    return;
  if (w_ <= 2 * WALL || h_ <= 2 * WALL)
    return;

  g_w = w_;
  g_h = h_;
  n = (size_t)w_ * (size_t)h_;

  rng = seed ? seed : 0x9e3779b9u;

  for (i = 0; i < n; i++)
    solid[i] = 0;
  for (y = 0; y < g_h; y++) {
    for (x = 0; x < g_w; x++) {
      if (x < WALL || x >= g_w - WALL || y < WALL || y >= g_h - WALL)
        solid[(size_t)y * g_w + x] = 1;
    }
  }

  /* Thin gas plus a dense square (64 cells at 20,92 on a 250 grid)
   * left of center that runs right as a wave. */
  x0 = on_grid(20, g_w);
  x1 = x0 + on_grid(64, g_w);
  y0 = on_grid(92, g_h);
  y1 = y0 + on_grid(64, g_h);

  for (y = 0; y < g_h; y++) {
    for (x = 0; x < g_w; x++) {
      double p;
      u8 s = 0;
      i = (size_t)y * g_w + x;
      if (solid[i]) {
        cur[i] = 0;
        continue;
      }
      p = (x >= x0 && x < x1 && y >= y0 && y < y1) ? burst : gas;
      if (rand01() < p)
        s |= 1;
      if (rand01() < p)
        s |= 2;
      if (rand01() < p)
        s |= 4;
      if (rand01() < p)
        s |= 8;
      cur[i] = s;
    }
  }
}

#define STREAM(P, S, C, I, J, BIT, BACK)                                       \
  do {                                                                         \
    if ((C) & (BIT)) {                                                         \
      if (!(S)[(J)])                                                           \
        (P)[(J)] |= (BIT);                                                     \
      else                                                                     \
        (P)[(I)] |= (BACK);                                                    \
    }                                                                          \
  } while (0)

void step(void) {
  size_t i, n = (size_t)g_w * (size_t)g_h;
  int x, y;
  u8 *t;

  for (i = 0; i < n; i++)
    nxtp[i] = 0;

  for (y = WALL; y < g_h - WALL; y++) {
    size_t row = (size_t)y * g_w;
    for (x = WALL; x < g_w - WALL; x++) {
      u8 st, c;
      i = row + (size_t)x;
      st = curp[i];
      if (!st)
        continue;
      c = (st == 5) ? 10 : (st == 10) ? 5 : st;
      STREAM(nxtp, solid, c, i, i + 1, 1, 4);
      STREAM(nxtp, solid, c, i, i - g_w, 2, 8);
      STREAM(nxtp, solid, c, i, i - 1, 4, 1);
      STREAM(nxtp, solid, c, i, i + g_w, 8, 2);
    }
  }

  t = curp;
  curp = nxtp;
  nxtp = t;
}

int cells(void) { return (int)(uintptr_t)curp; }
int solids(void) { return (int)(uintptr_t)solid; }
int width(void) { return g_w; }
int height(void) { return g_h; }
