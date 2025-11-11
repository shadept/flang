#include <stdio.h>

int getX(int p) {
    int* field_ptr_0 = (int*)((char*)p + 0);
    int field_load_1 = *field_ptr_0;
    return field_load_1;
}
struct Point {
    int x;
    int y;
};
int main(void) {
    struct Point alloca_0_val;
    struct Point* alloca_0 = &alloca_0_val;
    int* field_ptr_1 = (int*)((char*)alloca_0 + 0);
    *field_ptr_1 = 15;
    int* field_ptr_2 = (int*)((char*)alloca_0 + 4);
    *field_ptr_2 = 20;
    int* p = alloca_0;
    int call_3 = getX(p);
    return call_3;
}
