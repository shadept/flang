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
    return self.it.next().filter(self.f)
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
    return self.it.next().map(self.f)
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

// Not `.map(...)`: the mapping would capture `it` and `f`, and a
// capturing closure cannot decay into `map`'s bare `fn` parameter
// (E2111, RFC-014).
pub fn reduce(it: $I, f: fn($A, $T) A) A? {
    return it.next() match {
        Some(first) => Some(reduce(it, first, f))
        None => null
    }
}
