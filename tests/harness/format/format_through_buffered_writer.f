//! TEST: format_through_buffered_writer
//! EXIT: 0
//! STDOUT: buffered=[00042]

// A `Writer` wrapping another `Writer` is the case that proves the sink is not
// special-cased: the value formats the same whether the bytes land in a builder
// directly or pass through a buffer on the way.

import std.string_builder
import std.io.writer
import std.string
import core.io

pub fn main() i32 {
    let backing = [0u8; 64]
    let b = string_builder(64)
    defer b.deinit()

    let bw = buffered_writer(b.writer(), backing)
    42i32.format(bw.writer(), "05")
    bw.flush()

    println($"buffered=[{b.as_view()}]".as_view())
    return 0
}
