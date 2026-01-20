//! TEST: tuple_three_elements
//! EXIT: 60

// Three element tuple
// (10, 20, 30) desugars to .{ _0 = 10, _1 = 20, _2 = 30 }

pub fn main() i32 {
    let t = (10, 20, 30)
    return t.0 + t.1 + t.2
}
