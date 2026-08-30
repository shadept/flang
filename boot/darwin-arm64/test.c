/* std.test - allocation tracking behind the test allocator.
 *
 * `std.test`'s allocator forwards to malloc/realloc/free and reports every
 * block it hands out or takes back here. This file keeps the ledger: an
 * intrusive list of live blocks, plus the two calls the generated test
 * runner makes between tests.
 *
 *   run test -> passed -> __flang_test_epilogue()   count the live blocks
 *                        __flang_test_leak_sites()  where they came from
 *                        __flang_test_reset()       clear the ledger
 *            -> failed -> __flang_test_reset()      reset, say nothing
 *
 * A failing test reaches the runner through longjmp, which skips every
 * `defer` on the way out, so its live blocks say nothing about the code
 * under test and are not reported.
 *
 * The ledger's own nodes come from raw malloc and are never routed back
 * through the FLang allocator, so tracking cannot recurse.
 *
 * FLANG_LEAK_TRACE in the environment records a native stack per block and
 * reports the leaked ones grouped by stack. Off by default - a stack per
 * allocation costs both the capture and the memory to hold it.
 *
 * Single-threaded, like the rest of the FLang runtime.
 *
 * ponytail: singly-linked list, O(n) per free. Tests allocate in the
 * thousands, not the millions; swap in a hash table keyed on the pointer if
 * a suite ever spends real time here.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#include <windows.h>
#if defined(_MSC_VER)
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")
#define FLANG_LEAK_SYMBOLS 1
#endif
#elif defined(__GLIBC__) || defined(__APPLE__)
#include <execinfo.h>
#define FLANG_LEAK_SYMBOLS 1
#endif

/* Deep enough to reach past the allocator and the container that grew, to
   the FLang function that owns the allocation. */
#define FLANG_LEAK_FRAMES 16

struct flang_test_block {
    void *ptr;
    size_t size;
    struct flang_test_block *next;
    void *frames[FLANG_LEAK_FRAMES];
    int nframes;
};

/* -1 until the first allocation reads the environment. */
static int flang_leak_trace = -1;

static int flang_leak_tracing(void) {
    if (flang_leak_trace < 0) {
        const char *v = getenv("FLANG_LEAK_TRACE");
        flang_leak_trace = (v != NULL && v[0] != '\0' && v[0] != '0') ? 1 : 0;
    }
    return flang_leak_trace;
}

/* The stack above the tracker, or 0 frames when tracing is off or the
   platform has no capture. */
static int flang_leak_capture(void **frames) {
    if (!flang_leak_tracing()) {
        return 0;
    }
#if defined(_WIN32)
    /* Skips this function and its caller in the tracker. */
    return (int)CaptureStackBackTrace(2, FLANG_LEAK_FRAMES, frames, NULL);
#elif defined(FLANG_LEAK_SYMBOLS)
    /* The tracker's own frames stay in, at the top where nobody reads. */
    return backtrace(frames, FLANG_LEAK_FRAMES);
#else
    (void)frames;
    return 0;
#endif
}

static struct flang_test_block *flang_test_head = NULL;
static size_t flang_test_live = 0;
static size_t flang_test_live_bytes = 0;

void __flang_test_track_alloc(unsigned char *ptr, size_t size) {
    struct flang_test_block *b;
    if (ptr == NULL) {
        return;
    }
    b = (struct flang_test_block *)malloc(sizeof *b);
    if (b == NULL) {
        /* Out of memory for the ledger. The allocation itself stands; it
           just goes untracked, which under-reports rather than misreports. */
        return;
    }
    b->ptr = ptr;
    b->size = size;
    b->nframes = flang_leak_capture(b->frames);
    b->next = flang_test_head;
    flang_test_head = b;
    flang_test_live++;
    flang_test_live_bytes += size;
}

void __flang_test_track_realloc(unsigned char *old_ptr, unsigned char *new_ptr,
                                size_t new_size) {
    struct flang_test_block *b;
    if (new_ptr == NULL) {
        return;
    }
    for (b = flang_test_head; b != NULL; b = b->next) {
        if (b->ptr == old_ptr) {
            flang_test_live_bytes -= b->size;
            flang_test_live_bytes += new_size;
            b->ptr = new_ptr;
            b->size = new_size;
            return;
        }
    }
    /* Growing a block nobody handed out: record it, so the ledger still
       balances when the caller frees it. */
    __flang_test_track_alloc(new_ptr, new_size);
}

void __flang_test_track_free(unsigned char *ptr) {
    struct flang_test_block **link = &flang_test_head;
    if (ptr == NULL) {
        return;
    }
    while (*link != NULL) {
        struct flang_test_block *b = *link;
        if (b->ptr == ptr) {
            *link = b->next;
            flang_test_live--;
            flang_test_live_bytes -= b->size;
            free(b);
            return;
        }
        link = &b->next;
    }
}

/* Forget every block still tracked, so the next test starts from an empty
   ledger and reports only its own leaks.

   The tracked memory itself is NOT freed. What a test leaves behind is not
   always garbage: a lazily-initialized global built on the first test that
   needs it is still live for every test after, and reclaiming it here would
   hand the next test a dangling pointer. Leaked memory stays leaked for the
   life of the process, which is measured in seconds. */
void __flang_test_reset(void) {
    struct flang_test_block *b = flang_test_head;
    while (b != NULL) {
        struct flang_test_block *next = b->next;
        free(b);
        b = next;
    }
    flang_test_head = NULL;
    flang_test_live = 0;
    flang_test_live_bytes = 0;
}

/* One frame, as "name + hex offset" or the bare address when nothing
   resolves it. */
static void flang_leak_print_frame(void *addr) {
#if defined(_WIN32) && defined(FLANG_LEAK_SYMBOLS)
    char buf[sizeof(SYMBOL_INFO) + 512];
    SYMBOL_INFO *sym = (SYMBOL_INFO *)buf;
    DWORD64 disp = 0;
    sym->SizeOfStruct = sizeof(SYMBOL_INFO);
    sym->MaxNameLen = 511;
    if (SymFromAddr(GetCurrentProcess(), (DWORD64)(uintptr_t)addr, &disp, sym)) {
        printf("      %s +0x%llx\n", sym->Name, (unsigned long long)disp);
        return;
    }
#elif defined(FLANG_LEAK_SYMBOLS)
    char **names = backtrace_symbols(&addr, 1);
    if (names != NULL) {
        printf("      %s\n", names[0]);
        free(names);
        return;
    }
#endif
    printf("      %p\n", addr);
}

static int flang_leak_same_stack(const struct flang_test_block *a,
                                 const struct flang_test_block *b) {
    int i;
    if (a->nframes != b->nframes) {
        return 0;
    }
    for (i = 0; i < a->nframes; i++) {
        if (a->frames[i] != b->frames[i]) {
            return 0;
        }
    }
    return 1;
}

/* Every distinct allocation stack among the live blocks, with how many
   blocks and bytes were born there. Blocks with no stack (tracing off, or a
   platform with no capture) are skipped, so this prints nothing at all when
   FLANG_LEAK_TRACE is unset.

   ponytail: O(n^2) over the leaked blocks, which is a debug path over
   hundreds of blocks; sort by stack hash if a suite ever leaks thousands. */
void __flang_test_leak_sites(void) {
    struct flang_test_block *b;
    if (!flang_leak_tracing()) {
        return;
    }
#if defined(_WIN32) && defined(FLANG_LEAK_SYMBOLS)
    SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
    SymInitialize(GetCurrentProcess(), NULL, TRUE);
#endif
    for (b = flang_test_head; b != NULL; b = b->next) {
        struct flang_test_block *o;
        size_t blocks = 1;
        size_t bytes = b->size;
        int i;
        if (b->nframes == 0) {
            continue;
        }
        /* Fold every later block sharing this stack into the tally and clear
           its frame count, so the outer walk passes over it. The ledger is
           reset right after, so marking it up costs nothing. */
        for (o = b->next; o != NULL; o = o->next) {
            if (flang_leak_same_stack(o, b)) {
                blocks++;
                bytes += o->size;
                o->nframes = 0;
            }
        }
        printf("    %zu block(s), %zu byte(s) allocated at:\n", blocks, bytes);
        for (i = 0; i < b->nframes; i++) {
            flang_leak_print_frame(b->frames[i]);
        }
    }
#if defined(_WIN32) && defined(FLANG_LEAK_SYMBOLS)
    SymCleanup(GetCurrentProcess());
#endif
}

/* Blocks still live, with their total size through `out_bytes`. Says
   nothing and clears nothing: the runner owns the wording, and the ledger
   has to survive until `__flang_test_leak_sites` has walked it. */
size_t __flang_test_epilogue(size_t *out_bytes) {
    if (out_bytes != NULL) {
        *out_bytes = flang_test_live_bytes;
    }
    return flang_test_live;
}
