//! TEST: never_type_basic
//! EXIT: 42

pub fn main() i32 {
    let x = true match {
        true => 42,
        false => panic("unreachable")
    }
    return x
}
