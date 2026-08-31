//! TEST: slice_where_pointer_expected
//! COMPILE-ERROR: E2011

// A `u8[]` passed where a signature says `&u8`. The two have different shapes -
// a slice carries a length beside the pointer, and `&T` is non-null by type
// while a slice's `ptr` need not be - so a slice never stands in for a
// reference. Pass `.ptr`, or the address of an element.

import std.mem
import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let src = [65u8, 66u8, 67u8, 68u8]
    let dst = [0u8; 4]

    memcpy(dst[0..], src.ptr, 2usize)

    println($"{dst[0]},{dst[1]}".as_view())
    return 0
}
