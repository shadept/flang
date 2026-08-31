//! TEST: interp_user_format
//! EXIT: 0
//! STDOUT: Point(3, 4)

import std.string_builder
import std.io.writer
import std.string
import core.io

type Point = struct {
    x: i32
    y: i32
}

pub fn format(self: Point, w: Writer, spec: String) {
    w.write_str("Point(")
    self.x.format(w, "")
    w.write_str(", ")
    self.y.format(w, "")
    w.write_str(")")
}

pub fn main() i32 {
    let p = Point { x = 3i32, y = 4i32 }
    let msg = $"{p}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
