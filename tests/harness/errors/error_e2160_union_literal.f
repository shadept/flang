//! TEST: error_e2160_union_literal
//! COMPILE-ERROR: E2160

// A union literal writes exactly one member; two would overlap.

type Num = #foreign union {
    i: i32
    f: f32
}

pub fn main() i32 {
    const n = Num { i = 1, f = 2.0 }
    return n.i
}
