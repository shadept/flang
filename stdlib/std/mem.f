// Core memory management primitives
// These are C runtime functions that provide low-level memory operations

// Allocate memory from the heap
// Returns null pointer if allocation fails
#foreign pub fn malloc(size: usize) &u8?

// Reallocates the given area of memory
#foreign pub fn realloc(ptr: &u8?, size: usize) &u8?

// Free memory allocated by malloc
#foreign pub fn free(ptr: &u8?)
