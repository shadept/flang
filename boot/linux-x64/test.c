/* std.test - allocation tracking behind the test allocator.
 *
 * `std.test`'s allocator forwards to malloc/realloc/free and reports every
 * block it hands out or takes back here. This file keeps the ledger: an
 * intrusive list of live blocks, plus the two calls the generated test
 * runner makes between tests.
 *
 *   run test -> passed -> __flang_test_epilogue()   report leaks, then reset
 *            -> failed -> __flang_test_reset()      reset, say nothing
 *
 * A failing test reaches the runner through longjmp, which skips every
 * `defer` on the way out, so its live blocks say nothing about the code
 * under test and are not reported.
 *
 * The ledger's own nodes come from raw malloc and are never routed back
 * through the FLang allocator, so tracking cannot recurse.
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

struct flang_test_block {
    void *ptr;
    size_t size;
    struct flang_test_block *next;
};

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

/* Blocks still live, with their total size through `out_bytes`, then reset.
   Says nothing itself: the runner owns the output format, and a per-block
   listing of bare addresses is noise without a symbolizer to resolve them. */
size_t __flang_test_epilogue(size_t *out_bytes) {
    size_t count = flang_test_live;
    if (out_bytes != NULL) {
        *out_bytes = flang_test_live_bytes;
    }
    __flang_test_reset();
    return count;
}
