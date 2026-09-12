// Range types and iterator implementation for the iterator protocol.
//
// Ranges are created with the `..` operator:
//   0..10    - Range from 0 to 9 (exclusive end)
//
// The iterator protocol requires:
//   fn iter(r: &Range($T)) RangeIterator(T) - Creates iterator state
//   fn next(iter: &RangeIterator($T)) T? - Returns next value or null

// A (half-open) range bounded inclusively below and exclusively above (start..end). The range
// start..end contains all values with start <= x < end. It is empty if start >= end.
pub type Range = struct(T) {
    start: T
    end: T
}

pub fn op_index(self: &Range($T), index: usize) T? {
    if index < 0 or index >= self.end - self.start {
        return null
    }
    return Some(self.start + index)
}

// =============================================================================
// Range Iterator
// =============================================================================

// Iterator state for ranges
pub type RangeIterator = struct(T) {
    current: T
    end: T
}

// Create iterator from range
pub fn iter(self: &Range($T)) RangeIterator(T) {
    return .{ current = self.start, end = self.end }
}

// Advance iterator and return next value
pub fn next(self: &RangeIterator($T)) T? {
    if self.current >= self.end {
        return null
    }
    let val = self.current
    self.current = self.current + 1
    return Some(val)
}
