//! TEST: error_e1001_unexpected_token
//! COMPILE-ERROR: E1001

pub fn main() i32 {
    let x: i32 = 42;  // ERROR: unexpected token `;`
    return x
}
