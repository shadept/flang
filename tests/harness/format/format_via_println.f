//! TEST: format_via_println
//! EXIT: 0
//! STDOUT: <9>

// `println`'s generic fallback routes an arbitrary value through a local
// builder, so a type with only a `format` prints without a `println` of its own.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Tag = struct {
    n: i32,
}

pub fn format(self: &Tag, w: Writer, spec: String) {
    w.write_str("<")
    self.n.format(w, "")
    w.write_str(">")
}

pub fn main() i32 {
    println(Tag { n = 9i32 })
    return 0
}
