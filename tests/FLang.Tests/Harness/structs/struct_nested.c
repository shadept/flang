#include <stdio.h>

struct Inner {
    int value;
};
struct Outer {
    struct Inner inner;
    int extra;
};
int main(void) {
    struct Inner alloca_0_val;
    struct Inner* alloca_0 = &alloca_0_val;
    int* field_ptr_1 = (int*)((char*)alloca_0 + 0);
    *field_ptr_1 = 42;
    int* inner = alloca_0;
    struct Outer alloca_2_val;
    struct Outer* alloca_2 = &alloca_2_val;
    int* field_ptr_3 = (int*)((char*)alloca_2 + 0);
    *field_ptr_3 = inner;
    int* field_ptr_4 = (int*)((char*)alloca_2 + 4);
    *field_ptr_4 = 10;
    int* outer = alloca_2;
    int* field_ptr_5 = (int*)((char*)outer + 0);
    int field_load_6 = *field_ptr_5;
    int* field_ptr_7 = (int*)((char*)field_load_6 + 0);
    int field_load_8 = *field_ptr_7;
    return field_load_8;
}
