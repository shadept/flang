import std.option

// =============================================================================
// Filter
// =============================================================================

struct FilterIter(I, T) {
    it: I
    f: fn(T) bool
}

pub fn iter(self: &FilterIter($I, $T)) FilterIter(I, T) {
    return self.*
}

pub fn next(self: &FilterIter($I, $T)) T? {
    const el = self.it.next()
    if (el.has_value and self.f(el.value)) {
        return el
    }
    return null
}

pub fn filter(it: $I, f: fn($T) bool) FilterIter(I, T) {
    return .{ it = it, f = f }
}

// =============================================================================
// Map
// =============================================================================

struct MapIter(I, T, U) {
    it: I
    f: fn(T) U
}

pub fn iter(self: &MapIter($I, $T, $U)) MapIter(I, T, U) {
    return self.*
}

pub fn next(self: &MapIter($I, $T, $U)) U? {
    const el = self.it.next()
    if (el.has_value) {
        return self.f(el.value)
    }
    return null
}

pub fn map(it: $I, f: fn($T) $U) MapIter(I, T, U) {
    return .{ it = it, f = f }
}
