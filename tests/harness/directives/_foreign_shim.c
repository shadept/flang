#include <stdlib.h>

typedef union { float f; double d; } Num;

Num shim_twice(Num n) {
    Num r;
    r.d = n.d * 2.0;
    return r;
}

typedef struct Counter { int n; } Counter;

Counter* counter_new(int start) {
    Counter* c = malloc(sizeof(Counter));
    c->n = start;
    return c;
}

void counter_add(Counter* c, int by) { c->n += by; }
int counter_get(const Counter* c) { return c->n; }
void counter_free(Counter* c) { free(c); }
