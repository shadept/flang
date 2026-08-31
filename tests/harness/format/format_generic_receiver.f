//! TEST: format_generic_receiver
//! EXIT: 0
//! STDOUT: Box(7)/Box(  hi)/Box(002a)

// `format` declared on a generic struct dispatches per specialization, and
// forwards the spec on to the wrapped value's own append.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Box = struct(T) {
    v: T,
}

fn box_of(v: $T) Box(T) {
    return .{ v = v }
}

pub fn format(self: &Box($T), w: Writer, spec: String) {
    w.write_str("Box(")
    self.v.format(w, spec)
    w.write_str(")")
}

pub fn main() i32 {
    let sb = string_builder(64)
    defer sb.deinit()

    sb.append(box_of(7i32))
    sb.append("/")
    sb.append(box_of("hi"), ">4")
    sb.append("/")
    sb.append(box_of(42i32), "04x")

    println(sb.as_view())
    return 0
}
