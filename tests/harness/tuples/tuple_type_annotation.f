//! TEST: tuple_type_annotation
//! EXIT: 15

// Tuple type annotation: (i32, i32) desugars to { _0: i32, _1: i32 }

pub fn main() i32 {
    let t: (i32, i32) = (5, 10)
    return t.0 + t.1
}
