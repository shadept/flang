// Core memory management primitives
// These are C runtime functions that provide low-level memory operations

// Allocate memory from the heap
// Returns null pointer if allocation fails
#foreign fn malloc(size: usize) &u8?

// Free memory allocated by malloc
#foreign fn free(ptr: &u8?)

// Copy memory from source to destination
// dst and src must not overlap (use memmove for overlapping regions)
#foreign fn memcpy(dst: &u8, src: &u8, len: usize)

// Fill memory region with a byte value
#foreign fn memset(ptr: &u8, value: u8, len: usize)

// Copy memory from source to destination (handles overlapping regions)
#foreign fn memmove(dst: &u8, src: &u8, len: usize)

// Creates a slice from pointer and length.
pub fn slice_from_raw_parts(ptr: &$T, len: usize) T[] {
    return .{ ptr = ptr, len = len }
}