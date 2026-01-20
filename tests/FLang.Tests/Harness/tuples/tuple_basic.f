//! TEST: tuple_basic
//! EXIT: 30

// Basic tuple creation and access
// (10, 20) desugars to .{ _0 = 10, _1 = 20 }
// t.0 desugars to t._0

pub fn main() i32 {
    let t = (10, 20)
    return t.0 + t.1
}
