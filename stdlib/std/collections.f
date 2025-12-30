// Collection iterators for slices.
// Arrays automatically coerce to slices, so we only need SliceIterator.

import std.option

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
