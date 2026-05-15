//! TEST: type_alias_cycle
//! COMPILE-ERROR: E2036

type A = B
type B = A

pub fn main() i32 {
    let x: A = 0
    return 0
}
