// Atomic operations for thread-safe reference counting.
// Backed by C11 stdatomic.h via atomic.c.

#foreign fn __flang_atomic_load(ptr: &usize) usize
#foreign fn __flang_atomic_add(ptr: &usize, val: usize) usize
#foreign fn __flang_atomic_sub(ptr: &usize, val: usize) usize
