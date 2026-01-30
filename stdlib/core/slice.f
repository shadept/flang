import core.panic
import core.range

pub struct Slice(T) {
    ptr: &T
    len: usize
}

// Creates a slice from pointer and length.
pub fn slice_from_raw_parts(ptr: &$T, len: usize) T[] {
    return .{ ptr = ptr, len = len }
}

pub fn op_index(s: &Slice($T), index: usize) T {
    if (index >= s.len) {
        panic("index out of bounds")
    }

    const ptr = s.ptr + index
    return ptr.*
}

pub fn op_index(s: &Slice($T), index: Range(usize)) Slice(T) {
    // Clamp negative indices to 0
    let start = if (index.start < 0) 0 else index.start
    let end = if (index.end < 0) 0 else index.end

    // Clamp to valid bounds, return empty slice for invalid ranges
    if (start > s.len) { start = s.len }
    if (end > s.len) { end = s.len }
    if (start > end) { end = start }

    return .{
        ptr = s.ptr + start,
        len = end - start
    }
}

pub fn op_set_index(s: &Slice($T), index: usize, value: T) {
    if (index >= s.len) {
        panic("index out of bounds")
    }
    const slot = s.ptr + index
    slot.* = value
}

// =============================================================================
// Slice Iterator
// =============================================================================

// Slice Iterator
// Iterates over slices T[]
pub struct SliceIterator(T) {
    ptr: &T[]
    index: usize
    len: usize
}

// Create iterator from slice
pub fn iter(slice: &$T[]) SliceIterator(T) {
    return .{ ptr = slice, index = 0, len = slice.len }
}

// Advance slice iterator
pub fn next(iter: &SliceIterator($T)) T? {
    if (iter.index >= iter.len) {
        return null
    }
    let val: T = iter[iter.index]
    iter.index = iter.index + 1
    return val
}
