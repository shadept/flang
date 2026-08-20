import std.list
import std.test
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
    loop {
        self.it.next() match {
            Some(v) => if self.f(v) { return Some(v) } else { continue }
            None => return null
        }
        // once guards are supported
        // self.it.next() match {
        //     Some(v) if self.f(v) => return Some(v)
        //     None => return null
        //     _ => continue
        // }
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

// =============================================================================
// Tests
// =============================================================================

fn is_even(x: i32) bool { return x % 2 == 0 }

test "filter advances past non-matching elements" {
    // The non-matching head is the interesting case: `next` must skip
    // it and keep pulling, not report the iterator empty.
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)

    let it = xs.iter().filter(is_even)
    const first = it.next()
    assert_true(first.is_some(), "the 2 is found behind the non-matching 1")
    assert_eq(first.unwrap(), 2i32, "the first even element is 2")
    assert_true(it.next().is_none(), "and nothing follows it")
}

test "filter over an all-matching and an empty list" {
    let xs: List(i32) = list(2)
    defer xs.deinit()
    xs.push(4i32)
    xs.push(6i32)
    let it = xs.iter().filter(is_even)
    assert_eq(it.next().unwrap(), 4i32, "all-matching yields in order")
    assert_eq(it.next().unwrap(), 6i32, "second element follows")
    assert_true(it.next().is_none(), "then exhausts")

    let empty: List(i32) = list(0)
    defer empty.deinit()
    let e = empty.iter().filter(is_even)
    assert_true(e.next().is_none(), "empty stays empty")
}
