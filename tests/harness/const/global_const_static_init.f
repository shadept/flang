//! TEST: global_const_static_init
//! EXIT: 42

import std.option
import std.string

// A constant whose value is known during compilation is encoded into its global's bytes rather
// than written by an init function. This pins the encodings that reach the data segment: scalar
// widths and sign, a nested struct at its field offsets, a `String` view whose `ptr` is the
// address of another global, and `null` as a zeroed buffer.

type Inner = struct {
    a: u8
    b: i32
}

type Outer = struct {
    inner: Inner
    label: String
    missing: i32?
}

const NEG: i32 = -7
const WIDE: u64 = 0xFFFF_FFFF_FFFF_FFFF
const LETTER: char = 'A'
const FLAG: bool = true

const NESTED = Outer {
    inner = Inner { a = 200, b = -1 },
    label = "abc",
    missing = null,
}

pub fn main() i32 {
    if NEG != -7 {
        return 1
    }
    if WIDE != 0xFFFF_FFFF_FFFF_FFFF {
        return 2
    }
    if LETTER != 'A' {
        return 3
    }
    if !FLAG {
        return 4
    }
    if NESTED.inner.a != 200 {
        return 5
    }
    if NESTED.inner.b != -1 {
        return 6
    }
    if NESTED.label != "abc" {
        return 7
    }
    if NESTED.label.len != 3 {
        return 8
    }
    if NESTED.missing.is_some() {
        return 9
    }
    return 42
}
