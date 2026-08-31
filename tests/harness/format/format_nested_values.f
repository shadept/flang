//! TEST: format_nested_values
//! EXIT: 0
//! STDOUT: Pair(P(1,2), P(3,4))

// One `format` reaching another through the generic append: the inner type's
// impl is found from the outer impl's body.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Point = struct {
    x: i32,
    y: i32,
}

type Pair = struct {
    a: Point,
    b: Point,
}

pub fn format(self: &Point, w: Writer, spec: String) {
    w.write_str("P(")
    self.x.format(w, "")
    w.write_str(",")
    self.y.format(w, "")
    w.write_str(")")
}

pub fn format(self: &Pair, w: Writer, spec: String) {
    w.write_str("Pair(")
    self.a.format(w, "")
    w.write_str(", ")
    self.b.format(w, "")
    w.write_str(")")
}

pub fn main() i32 {
    let p = Pair {
        a = Point { x = 1i32, y = 2i32 },
        b = Point { x = 3i32, y = 4i32 },
    }
    println($"{p}".as_view())
    return 0
}
