#include <stdlib.h>
#include <string.h>

#include "../include/fx.h"

struct FxHandle {
    int32_t count;
};

FxHandle *fx_open(const char *name) {
    FxHandle *h = malloc(sizeof(FxHandle));
    h->count = (int32_t)strlen(name);
    return h;
}

int32_t fx_count(const FxHandle *h) { return h->count; }
void fx_close(FxHandle *h) { free(h); }

FxPoint fx_add(FxPoint a, FxPoint b) {
    FxPoint r = { a.x + b.x, a.y + b.y };
    return r;
}

FxValue fx_half(FxValue v, FxKind kind) {
    FxValue r;
    if (kind == FX_INT) {
        r.i = v.i / 2;
    } else {
        r.f = v.f / 2.0f;
    }
    return r;
}

int32_t fx_fold(const int32_t *xs, size_t n, FxReduce f) {
    int32_t acc = 0;
    for (size_t i = 0; i < n; i++) {
        acc = f(acc, xs[i]);
    }
    return acc;
}

static FxBits bits = { 3, 9 };
FxBits *fx_bits(void) { return &bits; }

int fx_log(const char *fmt, ...) { return (int)strlen(fmt); }
