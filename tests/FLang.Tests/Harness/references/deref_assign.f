//! TEST: deref_assign
//! EXIT: 99

pub fn main() i32 {
    let x: i32 = 42
    let ptr: &i32 = &x
    ptr.* = 99
    return x
}
