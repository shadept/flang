/* std.profile - probe runtime for `flang build --profile` (RFC-025).
 *
 * The compiler inserts `__flang_prof_enter(id)` at every function entry and
 * `__flang_prof_exit()` before every return, plus one `__flang_prof_register`
 * call at the top of main carrying the id -> name table. This file turns
 * those probes into a call tree:
 *
 *   root -> main -> parse -> lex        each edge is a ProfNode holding
 *        -> main -> check -> infer      calls + inclusive ticks
 *
 * Everything expensive is deferred to dump time. A probe pair on the hot
 * path costs two raw cycle-counter reads, a (usually one-compare) child
 * lookup, and a few stores - self time is interval-accounted as those
 * stores (each probe event closes an interval billed to the node that was
 * executing). Name lookup, aggregation, sorting, unit conversion, and
 * probe-overhead correction all happen once, at dump.
 *
 * Single-threaded, like the FLang runtime.
 *
 * Reports:
 *   - flat table on stderr at process exit (or __flang_prof_dump), sorted
 *     by self time
 *   - folded stacks ("a;b;c <self_ns>" per call path) written to the path
 *     `flang build --profile-out` baked in - the input format of
 *     speedscope / inferno / flamegraph.pl
 *
 * Sizing comes from the build, through __flang_profile_configure, which the
 * generated entry point calls before the first probe: `--profile-nodes`
 * (default 1Mi, 32 MB) caps distinct call paths and `--profile-depth`
 * (default 8192) caps live stack depth. PROF_FOLDED_MAX_MB caps the folded
 * file. Overrun never
 * corrupts pairing: an enter that cannot get a node or frame only bumps a
 * skip counter that its exit consumes, and the dump header reports how much
 * was dropped.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Clocks                                                             */
/* ------------------------------------------------------------------ */

/* Raw cycle counter: the cheapest monotonic-enough tick source on each
 * arch. Frequency is unknown here; dump() derives ns-per-tick from two
 * paired (ticks, ns) readings. Assumes an invariant counter (constant
 * rate, shared across cores), which holds on every supported target. */
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
static uint64_t prof_ticks(void) { return __rdtsc(); }
#elif defined(_MSC_VER) && defined(_M_ARM64)
#include <intrin.h>
static uint64_t prof_ticks(void) { return _ReadStatusReg(ARM64_SYSREG(3, 3, 14, 0, 2)); }
#elif defined(__x86_64__) || defined(__i386__)
#include <x86intrin.h>
static uint64_t prof_ticks(void) { return __rdtsc(); }
#elif defined(__aarch64__)
static uint64_t prof_ticks(void) {
    uint64_t v;
    __asm__ __volatile__("mrs %0, cntvct_el0" : "=r"(v));
    return v;
}
#else
static uint64_t prof_now_ns(void);
static uint64_t prof_ticks(void) { return prof_now_ns(); }
#endif

/* Wall reference used only to convert ticks to ns at dump time. Same
 * sources as std/time.c; duplicated so this file links on its own. */
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
static uint64_t prof_now_ns(void) {
    static LARGE_INTEGER freq = {0};
    LARGE_INTEGER now;
    if (freq.QuadPart == 0) {
        QueryPerformanceFrequency(&freq);
    }
    QueryPerformanceCounter(&now);
    uint64_t f = (uint64_t)freq.QuadPart;
    uint64_t t = (uint64_t)now.QuadPart;
    return (t / f) * 1000000000ULL + ((t % f) * 1000000000ULL) / f;
}
#else
#include <time.h>
static uint64_t prof_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
#endif

/* ------------------------------------------------------------------ */
/* Call tree                                                          */
/* ------------------------------------------------------------------ */

/* One edge of the call tree: "func_id called with this exact ancestry".
 * Children form a singly-linked, move-to-front list, so a repeated callee
 * is found on the first compare. Node 0 is the root (no function). */
typedef struct {
    uint32_t func_id;
    uint32_t first_child;  /* pool index; 0 = none (root is never a child) */
    uint32_t next_sibling;
    uint32_t parent;
    uint64_t calls;
    uint64_t total_ticks;  /* inclusive, outermost spans only */
    /* Exact self time: every probe event closes an interval billed to
     * the node that was executing (`prof_last_stamp` marks the previous
     * event). Deriving self from spans minus child spans instead would
     * mis-attribute under recursion collapse: a recursive re-entry's
     * subtree hangs under the OUTER node, so the frames temporally in
     * between would absorb its whole cost into their "self". */
    uint64_t self_ticks;
} ProfNode;

typedef struct {
    /* Pool index; PROF_PASS marks a recursive re-entry frame, whose
     * t_enter slot holds the prof_current to restore instead of a time. */
    uint32_t node;
    uint64_t t_enter;
} ProfFrame;

#define PROF_PASS 0x80000000u

static ProfNode* prof_pool;      /* [0] is the root; NULL = profiler off */
static uint32_t prof_pool_cap;
static uint32_t prof_pool_used;
static ProfFrame* prof_stack;
static uint32_t prof_stack_cap;
static uint32_t prof_depth;
static uint32_t prof_current;    /* node whose frame we are inside */

/* Enters that could not get a node or frame. While nonzero, every nested
 * enter joins it and every exit drains it first - LIFO order keeps real
 * frames paired with real exits. */
static uint64_t prof_skipped;
static uint64_t prof_dropped_edges;   /* node-pool misses, for the report */
static uint64_t prof_dropped_frames;  /* stack-cap misses, for the report */

/* Name table: `count` names, newline-separated, in id order. The blob is
 * a data-segment global in the generated C - borrowed, never freed. */
static uint32_t prof_func_count;
static const char* prof_names;
static int64_t prof_names_len;

/* Recursion collapse: per-function pool index of the node whose span is
 * currently open, or 0. A re-entry of an active function reuses that
 * node instead of minting a new path per recursion level - without
 * this, a deeply recursive program (the compiler's own checker) mints
 * millions of one-off paths that exhaust the pool and bloat the folded
 * output, while telling the reader nothing a single frame would not. */
static uint32_t* prof_active;

/* The previous probe event's clock reading; the interval since it bills
 * to whichever node was executing (see ProfNode.self_ticks). */
static uint64_t prof_last_stamp;

/* Paired readings for tick -> ns conversion, taken at register time. */
static uint64_t prof_base_ticks;
static uint64_t prof_base_ns;

/* Measured cost of one probe pair, in ticks (see calibration below). */
static double prof_pair_wall;    /* what the caller loses per child call */
static double prof_pair_inner;   /* what an empty callee accrues itself */

/* ------------------------------------------------------------------ */
/* Probes                                                             */
/* ------------------------------------------------------------------ */

void __flang_prof_enter(int32_t fid) {
    if (!prof_pool) {
        return;
    }
    if (prof_skipped || prof_depth >= prof_stack_cap) {
        prof_skipped++;
        if (prof_depth >= prof_stack_cap) {
            prof_dropped_frames++;
        }
        return;
    }

    uint32_t act = prof_active[(uint32_t)fid];
    if (act) {
        /* Recursive re-entry: fold into the open span. The call is
         * counted; no inclusive span is opened (the outer one already
         * covers it), and deeper distinct calls hang under the same
         * node. The frame remembers where to put prof_current back. */
        prof_pool[act].calls++;
        prof_stack[prof_depth].node = act | PROF_PASS;
        prof_stack[prof_depth].t_enter = prof_current;
        prof_depth++;
        uint64_t rt = prof_ticks();
        prof_pool[prof_current].self_ticks += rt - prof_last_stamp;
        prof_last_stamp = rt;
        prof_current = act;
        return;
    }

    ProfNode* cur = &prof_pool[prof_current];
    uint32_t idx = cur->first_child;
    uint32_t prev = 0;
    while (idx && prof_pool[idx].func_id != (uint32_t)fid) {
        prev = idx;
        idx = prof_pool[idx].next_sibling;
    }
    if (!idx) {
        if (prof_pool_used >= prof_pool_cap) {
            prof_dropped_edges++;
            prof_skipped++;
            return;
        }
        idx = prof_pool_used++;
        ProfNode* n = &prof_pool[idx];
        n->func_id = (uint32_t)fid;
        n->first_child = 0;
        n->next_sibling = cur->first_child;
        n->parent = prof_current;
        n->calls = 0;
        n->total_ticks = 0;
        cur->first_child = idx;
    } else if (prev) {
        /* Move to front: the next call from this parent is likely the
         * same callee, making the lookup a single compare. */
        prof_pool[prev].next_sibling = prof_pool[idx].next_sibling;
        prof_pool[idx].next_sibling = cur->first_child;
        cur->first_child = idx;
    }

    prof_pool[idx].calls++;
    prof_active[(uint32_t)fid] = idx;
    prof_stack[prof_depth].node = idx;
    /* Clock read is the LAST thing before the callee runs: the lookup
     * above bills to the caller, where dump's calibration removes it. */
    uint64_t t = prof_ticks();
    prof_stack[prof_depth].t_enter = t;
    prof_pool[prof_current].self_ticks += t - prof_last_stamp;
    prof_last_stamp = t;
    prof_depth++;
    prof_current = idx;
}

void __flang_prof_exit(void) {
    /* Clock read FIRST, so the unwind below bills to the caller. */
    uint64_t t = prof_ticks();
    if (!prof_pool) {
        return;
    }
    if (prof_skipped) {
        prof_skipped--;
        return;
    }
    if (!prof_depth) {
        return;
    }
    prof_depth--;
    uint32_t enc = prof_stack[prof_depth].node;
    if (enc & PROF_PASS) {
        prof_pool[enc & ~PROF_PASS].self_ticks += t - prof_last_stamp;
        prof_last_stamp = t;
        prof_current = (uint32_t)prof_stack[prof_depth].t_enter;
        return;
    }
    ProfNode* n = &prof_pool[enc];
    n->self_ticks += t - prof_last_stamp;
    prof_last_stamp = t;
    n->total_ticks += t - prof_stack[prof_depth].t_enter;
    prof_active[n->func_id] = 0;
    prof_current = n->parent;
}

/* ------------------------------------------------------------------ */
/* Registration                                                       */
/* ------------------------------------------------------------------ */

/* Byte budget for the folded file. Beyond it the heaviest paths are kept
   and the rest reported as dropped. */
#define PROF_FOLDED_MAX_MB 32

static uint32_t prof_cfg_nodes = 0;
static uint32_t prof_cfg_depth = 0;
static const char* prof_cfg_out = NULL;

/* The build's `-p` knobs, handed over by the generated entry point before
   any probe fires. A zero keeps the default below; a null path writes no
   folded output. */
void __flang_profile_configure(unsigned int nodes, unsigned int depth,
                               const char* out) {
    prof_cfg_nodes = (uint32_t)nodes;
    prof_cfg_depth = (uint32_t)depth;
    prof_cfg_out = out;
}

static uint32_t prof_limit(uint32_t configured, uint32_t fallback) {
    if (configured < 16 || configured > 0x40000000UL) {
        return fallback;
    }
    return configured;
}

/* Run probe pairs against the empty tree and time them, so dump() can
 * subtract what the probes themselves cost from self times. Two numbers
 * come out: the wall cost of a full pair as seen by the caller, and the
 * slice of it that lands between the two clock reads, i.e. what an empty
 * callee gets billed. The scratch nodes are wiped afterwards. */
static void prof_calibrate(void) {
    enum { K = 16384 };
    prof_last_stamp = prof_ticks();
    uint64_t w0 = prof_ticks();
    for (int i = 0; i < K; i++) {
        __flang_prof_enter(0);
        __flang_prof_exit();
    }
    uint64_t w1 = prof_ticks();

    uint64_t inner = prof_pool[prof_pool[0].first_child].total_ticks;
    prof_pair_wall = (double)(w1 - w0) / K;
    prof_pair_inner = (double)inner / K;

    memset(prof_pool, 0, (size_t)prof_pool_used * sizeof(ProfNode));
    prof_pool_used = 1;
    prof_current = 0;
    prof_depth = 0;
    prof_last_stamp = prof_ticks();
}

void __flang_prof_dump(void);

void __flang_prof_register(int64_t count, const void* names, int64_t names_len) {
    if (prof_pool) {
        return;
    }
    prof_func_count = (uint32_t)count;
    prof_names = (const char*)names;
    prof_names_len = names_len;

    prof_pool_cap = prof_limit(prof_cfg_nodes, 1 << 20);
    prof_stack_cap = prof_limit(prof_cfg_depth, 8192);
    prof_pool = (ProfNode*)calloc(prof_pool_cap, sizeof(ProfNode));
    prof_stack = (ProfFrame*)malloc((size_t)prof_stack_cap * sizeof(ProfFrame));
    prof_active = (uint32_t*)calloc(prof_func_count ? prof_func_count : 1, sizeof(uint32_t));
    if (!prof_pool || !prof_stack || !prof_active) {
        fprintf(stderr, "flang profile: allocation failed, profiling disabled\n");
        free(prof_pool);
        free(prof_stack);
        free(prof_active);
        prof_pool = NULL;
        prof_stack = NULL;
        prof_active = NULL;
        return;
    }
    prof_pool_used = 1; /* node 0 is the root */

    prof_calibrate();
    prof_base_ticks = prof_ticks();
    prof_base_ns = prof_now_ns();
    atexit(__flang_prof_dump);
}

/* ------------------------------------------------------------------ */
/* Reports                                                            */
/* ------------------------------------------------------------------ */

static double prof_ns_per_tick(void) {
    uint64_t dt = prof_ticks() - prof_base_ticks;
    uint64_t dn = prof_now_ns() - prof_base_ns;
    if (dt == 0) {
        return 1.0;
    }
    return (double)dn / (double)dt;
}

/* Self ticks per node, probe overhead removed: the interval-accounted
 * self, minus the wall cost of the pairs run for direct children, minus
 * the inner slice of this node's own pairs. Clamped - a short function
 * can measure below its own probe cost. The pool is never mutated, so a
 * mid-run dump leaves accounting intact; `now` virtually closes the
 * interval that is still open (billed to the executing node). */
static double* prof_adjusted_self(uint64_t* child_calls, uint64_t now) {
    double* self = (double*)calloc(prof_pool_used, sizeof(double));
    if (!self) {
        return NULL;
    }
    for (uint32_t i = 1; i < prof_pool_used; i++) {
        self[i] = (double)prof_pool[i].self_ticks;
        child_calls[prof_pool[i].parent] += prof_pool[i].calls;
    }
    if (prof_current) {
        self[prof_current] += (double)(now - prof_last_stamp);
    }
    for (uint32_t i = 0; i < prof_pool_used; i++) {
        self[i] -= (double)child_calls[i] * (prof_pair_wall - prof_pair_inner);
        self[i] -= (double)prof_pool[i].calls * prof_pair_inner;
        if (self[i] < 0) {
            self[i] = 0;
        }
    }
    return self;
}

/* Inclusive ticks per node, with every span still open on the stack
 * virtually closed at `now` - a mid-run dump (or a process ending via
 * exit()) must not report the frames it is inside as zero-width. Each
 * non-passthrough frame is a distinct node (a same-function re-entry is
 * a passthrough), so no node is closed twice. */
static double* prof_inclusive(uint64_t now) {
    double* incl = (double*)calloc(prof_pool_used, sizeof(double));
    if (!incl) {
        return NULL;
    }
    for (uint32_t i = 1; i < prof_pool_used; i++) {
        incl[i] = (double)prof_pool[i].total_ticks;
    }
    for (uint32_t d = 0; d < prof_depth; d++) {
        uint32_t enc = prof_stack[d].node;
        if (!(enc & PROF_PASS)) {
            incl[enc] += (double)(now - prof_stack[d].t_enter);
        }
    }
    return incl;
}

/* Split the name blob into per-id (ptr, len) pairs. */
static int prof_split_names(const char** ptrs, uint32_t* lens) {
    const char* p = prof_names;
    const char* end = prof_names + prof_names_len;
    for (uint32_t i = 0; i < prof_func_count; i++) {
        const char* nl = memchr(p, '\n', (size_t)(end - p));
        if (!nl) {
            return 0;
        }
        ptrs[i] = p;
        lens[i] = (uint32_t)(nl - p);
        p = nl + 1;
    }
    return 1;
}

typedef struct {
    uint32_t func_id;
    uint64_t calls;
    double self_ticks;
    double incl_ticks;
} ProfRow;

static int prof_row_cmp(const void* a, const void* b) {
    double x = ((const ProfRow*)a)->self_ticks;
    double y = ((const ProfRow*)b)->self_ticks;
    return (x < y) - (x > y);
}

/* qsort context (single-threaded, like everything here). */
static const double* prof_sort_self;

static int prof_node_cmp(const void* a, const void* b) {
    double x = prof_sort_self[*(const uint32_t*)a];
    double y = prof_sort_self[*(const uint32_t*)b];
    return (x < y) - (x > y);
}

static int prof_index_cmp(const void* a, const void* b) {
    uint32_t x = *(const uint32_t*)a;
    uint32_t y = *(const uint32_t*)b;
    return (x > y) - (x < y);
}

/* Folded lines are independent of each other and of order, so the byte
 * budget (PROF_FOLDED_MAX_MB) keeps the HEAVIEST paths - what it
 * drops is the lightest tail, which a flamegraph could not have
 * rendered visibly anyway. The kept lines are then written in pool
 * order: nodes are minted at first entry, so the file reads in the
 * order each path first ran, and a viewer's time-ordered layout shows
 * the program's phases left to right. */
static void prof_write_folded(const char* path, const double* self, double ns_per_tick,
                              const char** names, const uint32_t* lens) {
    FILE* f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "flang profile: cannot write %s\n", path);
        return;
    }
    uint64_t budget = (uint64_t)PROF_FOLDED_MAX_MB * 1024 * 1024;

    uint32_t* chain = (uint32_t*)malloc((size_t)prof_stack_cap * sizeof(uint32_t));
    uint32_t* order = (uint32_t*)malloc((size_t)prof_pool_used * sizeof(uint32_t));
    if (!chain || !order) {
        free(chain);
        free(order);
        fclose(f);
        return;
    }

    /* A zero-self path adds no width, and it still renders as the
     * prefix of whichever descendants have weight. Self alone gates the
     * line - a node can hold time with zero calls (a frame open across
     * a reset()). */
    uint32_t count = 0;
    for (uint32_t i = 1; i < prof_pool_used; i++) {
        if ((uint64_t)(self[i] * ns_per_tick) > 0) {
            order[count++] = i;
        }
    }
    prof_sort_self = self;
    qsort(order, count, sizeof(uint32_t), prof_node_cmp);

    /* Estimated bytes per line: every frame name on the path, plus
     * separators and the count column. */
    uint32_t keep = count;
    double dropped_ns = 0;
    uint64_t est = 0;
    for (uint32_t o = 0; o < count && keep == count; o++) {
        est += 24;
        for (uint32_t at = order[o]; at; at = prof_pool[at].parent) {
            uint32_t fid = prof_pool[at].func_id;
            est += (fid < prof_func_count ? lens[fid] : 8) + 1;
        }
        if (est > budget) {
            keep = o;
        }
    }
    for (uint32_t o = keep; o < count; o++) {
        dropped_ns += self[order[o]] * ns_per_tick;
    }
    qsort(order, keep, sizeof(uint32_t), prof_index_cmp);

    for (uint32_t o = 0; o < keep; o++) {
        uint32_t i = order[o];
        uint32_t n = 0;
        for (uint32_t at = i; at && n < prof_stack_cap; at = prof_pool[at].parent) {
            chain[n++] = prof_pool[at].func_id;
        }
        for (uint32_t k = n; k > 0; k--) {
            uint32_t fid = chain[k - 1];
            if (fid < prof_func_count) {
                fwrite(names[fid], 1, lens[fid], f);
            }
            if (k > 1) {
                fputc(';', f);
            }
        }
        fprintf(f, " %llu\n", (unsigned long long)(uint64_t)(self[i] * ns_per_tick));
    }
    free(chain);
    free(order);
    fclose(f);

    fprintf(stderr, "flang profile: %u folded paths written to %s", keep, path);
    if (keep < count) {
        fprintf(stderr, " (byte budget dropped the %u lightest paths, %.3f ms total)",
            count - keep, dropped_ns / 1e6);
    }
    fprintf(stderr, "\n");
}

void __flang_prof_dump(void) {
    if (!prof_pool || prof_pool_used <= 1) {
        return;
    }
    uint64_t now = prof_ticks();
    double ns_per_tick = prof_ns_per_tick();

    uint64_t* child_calls = (uint64_t*)calloc(prof_pool_used, sizeof(uint64_t));
    if (!child_calls) {
        return;
    }
    double* self = prof_adjusted_self(child_calls, now);
    free(child_calls);
    if (!self) {
        return;
    }
    double* incl = prof_inclusive(now);

    const char** names = (const char**)calloc(prof_func_count, sizeof(char*));
    uint32_t* lens = (uint32_t*)calloc(prof_func_count, sizeof(uint32_t));
    ProfRow* rows = (ProfRow*)calloc(prof_func_count, sizeof(ProfRow));
    if (!incl || !names || !lens || !rows || !prof_split_names(names, lens)) {
        goto out;
    }

    for (uint32_t i = 0; i < prof_func_count; i++) {
        rows[i].func_id = i;
    }
    for (uint32_t i = 1; i < prof_pool_used; i++) {
        uint32_t fid = prof_pool[i].func_id;
        if (fid >= prof_func_count) {
            continue;
        }
        rows[fid].calls += prof_pool[i].calls;
        rows[fid].self_ticks += self[i];
        /* Recursion collapse guarantees no node has a same-function
         * ancestor, so summing totals never double-counts a span. */
        rows[fid].incl_ticks += incl[i];
    }
    qsort(rows, prof_func_count, sizeof(ProfRow), prof_row_cmp);

    fprintf(stderr, "\nflang profile: %u functions, %u call paths",
        prof_func_count, prof_pool_used - 1);
    if (prof_dropped_edges || prof_dropped_frames) {
        fprintf(stderr,
            " (TRUNCATED: %llu enters lost to the node pool, %llu to stack depth;"
            " raise --profile-nodes / --profile-depth)",
            (unsigned long long)prof_dropped_edges,
            (unsigned long long)prof_dropped_frames);
    }
    fprintf(stderr, "\n%12s %12s %12s %12s  %s\n",
        "calls", "self ms", "incl ms", "ns/call", "function");
    for (uint32_t i = 0; i < prof_func_count; i++) {
        /* A row can carry time with zero calls: a frame that was open
         * across a reset() accrues post-reset self while its call was
         * counted before the reset. Show the time; ns/call has no
         * denominator then. */
        if (!rows[i].calls && rows[i].self_ticks <= 0) {
            continue;
        }
        double self_ms = rows[i].self_ticks * ns_per_tick / 1e6;
        double incl_ms = rows[i].incl_ticks * ns_per_tick / 1e6;
        double per_call = rows[i].calls
            ? rows[i].self_ticks * ns_per_tick / (double)rows[i].calls
            : 0;
        fprintf(stderr, "%12llu %12.3f %12.3f %12.1f  %.*s\n",
            (unsigned long long)rows[i].calls, self_ms, incl_ms, per_call,
            (int)lens[rows[i].func_id], names[rows[i].func_id]);
    }
    if (prof_cfg_out && *prof_cfg_out) {
        prof_write_folded(prof_cfg_out, self, ns_per_tick, names, lens);
    }

out:
    free(rows);
    free(lens);
    free(names);
    free(incl);
    free(self);
}

void __flang_prof_reset(void) {
    if (!prof_pool) {
        return;
    }
    for (uint32_t i = 0; i < prof_pool_used; i++) {
        prof_pool[i].calls = 0;
        prof_pool[i].total_ticks = 0;
        prof_pool[i].self_ticks = 0;
    }
    prof_dropped_edges = 0;
    prof_dropped_frames = 0;
    prof_last_stamp = prof_ticks();
}
