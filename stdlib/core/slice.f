import core.panic
import core.range

pub struct Slice(T) {
    ptr: &T
    len: usize
}

pub fn op_index(s: &Slice($T), index: usize) &T {
    if (index >= s.len) {
        panic("index out of bounds")
    }
    return s.ptr + index
}

pub fn op_index(s: &Slice($T), index: Range) Slice(T) {
    // Clamp negative indices to 0
    let start = if (index.start < 0) 0 else index.start as usize
    let end = if (index.end < 0) 0 else index.end as usize

    // Clamp to valid bounds, return empty slice for invalid ranges
    if (start > s.len) { start = s.len }
    if (end > s.len) { end = s.len }
    if (start > end) { end = start }

    return .{
        ptr = s.ptr + start,
        len = end - start
    }
}
