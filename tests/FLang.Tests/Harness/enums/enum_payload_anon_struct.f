//! TEST: enum_payload_anon_struct
//! EXIT: 42

// Variant construction with an anonymous-struct literal at the payload
// position must coerce to the variant's nominal payload type — the
// lowering pass passes the payload type as the expected type so the
// `.{ ... }` materialises as the named struct, not its `__anon_*`
// synthesis.

type Point = struct {
    x: i32
    y: i32
}

type Shape = enum {
    Pt(Point)
    Empty
}

pub fn main() i32 {
    let s: Shape = Shape.Pt(.{ x = 20i32, y = 22i32 })
    return s match {
        Pt(p) => p.x + p.y,
        Empty => 0i32,
    }
}
