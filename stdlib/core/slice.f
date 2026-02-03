import core.panic
import core.range

// A view into a contiguous sequence of elements of type T.
// A Slice does not own ptr.
pub struct Slice(T) {
    ptr: &T
    len: usize
}

// Creates a slice from pointer and length.
pub fn slice_from_raw_parts(ptr: &$T, len: usize) T[] {
    return .{ ptr, len }
}

pub fn get(s: Slice($T), idx: usize) u8? {
    if (idx >= s.len) {
        return null
    }
    const ptr = s.ptr + idx
    return ptr.*
}

pub fn op_index(s: Slice($T), idx: usize) T {
    if (idx >= s.len) {
        panic("index out of bounds")
    }

    const ptr = s.ptr + idx
    return ptr.*
}

pub fn op_index(s: Slice($T), range: Range(usize)) Slice(T) {
    let start = range.start
    let end = range.end

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
    ptr: T[]
    index: usize
    len: usize
}

// Create iterator from slice
pub fn iter(slice: &$T[]) SliceIterator(T) {
    return .{ ptr = slice.*, index = 0, len = slice.len }
}

// Advance slice iterator
pub fn next(iter: &SliceIterator($T)) T? {
    if (iter.index >= iter.len) {
        return null
    }
    let val: T = iter.*[iter.index]
    iter.index = iter.index + 1
    return val
}

pub fn op_index(iter: &SliceIterator($T), index: usize) T {
    if (index >= iter.len) {
        panic("index out of bounds")
    }

    const ptr = iter.ptr.ptr + index
    return ptr.*
}
