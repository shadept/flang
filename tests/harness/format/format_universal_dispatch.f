//! TEST: format_universal_dispatch
//! EXIT: 0
//! STDOUT: 00042|2.50|  true|hi  | z |ff|P007|

// Every builtin has a `format`, so a generic body can format whatever it was
// handed without knowing which types have an `append` overload of their own.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Point = struct {
    x: i32,
    y: i32,
}

pub fn format(self: Point, w: Writer, spec: String) {
    w.write_str("P")
    self.x.format(w, spec)
}

fn show(w: Writer, v: $T, spec: String) {
    v.format(w, spec)
    w.write_str("|")
}

pub fn main() i32 {
    let sb = string_builder(128)
    defer sb.deinit()
    const w = sb.writer()

    show(w, 42i32, "05")
    show(w, 2.5f64, ".2")
    show(w, true, ">6")
    show(w, "hi", "<4")
    show(w, 'z', "^3")
    show(w, 255u8, "x")
    show(w, Point { x = 7i32, y = 0i32 }, "03")

    println(sb.as_view())
    return 0
}
