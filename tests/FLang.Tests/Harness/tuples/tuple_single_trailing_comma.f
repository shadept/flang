//! TEST: tuple_single_trailing_comma
//! EXIT: 42

// Single element tuple (with trailing comma)
// (42,) desugars to .{ _0 = 42 }

pub fn main() i32 {
    let t = (42,)
    return t.0
}
