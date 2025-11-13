//! TEST: ptr_usize_roundtrip
//! EXIT: 42

pub fn main() i32 {
    let x: i32 = 42
    let p: &i32 = &x

    let addr: usize = p as usize
    let p2: &i32 = addr as &i32

    return p2.*
}
