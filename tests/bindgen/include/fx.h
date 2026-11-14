#ifndef FX_H
#define FX_H

#include <stddef.h>
#include <stdint.h>

#define FX_VERSION "1.2"
#define FX_FLAG_A 0x1u
#define FX_FLAG_B (1u << 3)
#define FX_SCALE 2.5f

typedef struct FxHandle FxHandle;

typedef enum FxKind { FX_INT = 1, FX_REAL } FxKind;

typedef struct FxPoint {
    int32_t x;
    int32_t y;
} FxPoint;

typedef union FxValue {
    int32_t i;
    float f;
} FxValue;

typedef struct FxBits {
    unsigned low : 4;
    unsigned high : 4;
} FxBits;

typedef int32_t (*FxReduce)(int32_t acc, int32_t x);

FxHandle *fx_open(const char *name);
int32_t fx_count(const FxHandle *h);
void fx_close(FxHandle *h);
FxPoint fx_add(FxPoint a, FxPoint b);
FxValue fx_half(FxValue v, FxKind kind);
int32_t fx_fold(const int32_t *xs, size_t n, FxReduce f);
FxBits *fx_bits(void);
int fx_log(const char *fmt, ...);

#endif
