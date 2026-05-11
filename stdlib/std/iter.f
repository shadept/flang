import std.option

// =============================================================================
// Filter
// =============================================================================

type FilterIter = struct(I, T) {
    it: I
    f: fn(T) bool
}

pub fn iter(self: &FilterIter($I, $T)) FilterIter(I, T) {
    return self.*
}

pub fn next(self: &FilterIter($I, $T)) T? {
    return self.it.next() match {
        Some(v) => if self.f(v) { Some(v) } else { null }
        None => null
    }
}

pub fn filter(it: $I, f: fn($T) bool) FilterIter(I, T) {
    return .{ it = it, f = f }
}

// =============================================================================
// Map
// =============================================================================

type MapIter = struct(I, T, U) {
    it: I
    f: fn(T) U
}

pub fn iter(self: &MapIter($I, $T, $U)) MapIter(I, T, U) {
    return self.*
}

pub fn next(self: &MapIter($I, $T, $U)) U? {
    return self.it.next() match {
        Some(v) => self.f(v)
        None => null
    }
}

pub fn map(it: $I, f: fn($T) $U) MapIter(I, T, U) {
    return .{ it = it, f = f }
}


// =============================================================================
// Reduce
// =============================================================================

pub fn reduce(it: $I, init: $A, f: fn(A, $T) A) A {
    let acc = init
    for item in it {
        acc = f(acc, item)
    }
    return acc
}

pub fn reduce(it: $I, f: fn($A, $T) A) A? {
    return it.next() match {
        Some(first) => reduce(it, first, f)
        None => null
    }
}
