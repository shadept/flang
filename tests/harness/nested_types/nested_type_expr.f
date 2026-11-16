//! TEST: nested_type_expr
//! EXIT: 23

// RFC-046: a nested type in expression position - a struct literal, a variant through the path, and
// a reified type.
type Shape = struct {
    type Size = struct { w: i32, h: i32 }
    type Kind = enum { Square, Wide(i32) }
    size: Size
    kind: Kind
}

type Box = struct(T) {
    type Cell = struct { v: T }
    c: Cell
}

pub fn main() i32 {
    const sz: Shape.Size = Shape.Size { w = 2, h = 3 }
    const k: Shape.Kind = Shape.Kind.Wide(4)
    const q: Shape.Kind = Shape.Kind.Square
    const c: Box(i32).Cell = Box(i32).Cell { v = 5 }
    const n: usize = size_of(Shape.Size)
    const s: Shape = Shape { size = sz, kind = k }
    const kv: i32 = s.kind match {
        Square => 0
        Wide(x) => x
    }
    return sz.w * sz.h + kv + c.v + (n as i32)
}
