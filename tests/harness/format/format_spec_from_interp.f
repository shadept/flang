//! TEST: format_spec_from_interp
//! EXIT: 0
//! STDOUT: a[-]b[04]c[>10]

// A hole's format spec reaches a user `format` unchanged whatever it says, and
// a hole without one arrives as the empty string.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Tag = struct {
    n: i32,
}

pub fn format(self: &Tag, w: Writer, spec: String) {
    w.write_str("[")
    if spec.len == 0 {
        w.write_str("-")
    } else {
        spec.format(w, "")
    }
    w.write_str("]")
}

pub fn main() i32 {
    let t = Tag { n = 1 }
    let msg = $"a{t}b{t:04}c{t:>10}"
    defer msg.deinit()
    println(msg.as_view())
    return 0
}
