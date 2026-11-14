//! TEST: error_e2162_union_pattern
//! COMPILE-ERROR: E2162

// Without a tag, every arm of a union pattern would match.

type Num = #foreign union {
    i: i32
    f: f32
}

pub fn main() i32 {
    const n = Num { i = 1 }
    return n match {
        Num { i } => i
    }
}
