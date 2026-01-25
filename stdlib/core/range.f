// Range types and iterator implementation for the iterator protocol.
//
// Ranges are created with the `..` operator:
//   0..10    - Range from 0 to 9 (exclusive end)
//
// The iterator protocol requires:
//   fn iter(r: &Range) RangeIterator - Creates iterator state
//   fn next(iter: &RangeIterator) isize? - Returns next value or null

// A (half-open) range bounded inclusively below and exclusively above (start..end).
// The range start..end contains all values with start <= x < end. It is empty if start >= end.
pub struct Range {
    start: isize
    end: isize
}

pub fn op_index(r: &Range, index: isize) isize? {
    if (index < 0) {
        return null
    }
    if (index >= r.end - r.start) {
        return null
    }
    return r.start + index
}

// Iterator state for ranges
pub struct RangeIterator {
    current: isize
    end: isize
}

// Create iterator from range
pub fn iter(r: &Range) RangeIterator {
    return .{ current = r.start, end = r.end }
}

// Advance iterator and return next value
pub fn next(iter: &RangeIterator) isize? {
    if (iter.current >= iter.end) {
        return null
    }
    let val = iter.current
    iter.current = iter.current + 1
    return val
}
