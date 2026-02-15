//! TEST: error_e2075_match_arm_mismatch
//! COMPILE-ERROR: E2075

enum Color { Red, Blue }
fn get_int() i32 { return 42 }

pub fn main() i32 {
    let c = Color.Red
    let x = c match {
        Red => get_int(),
        Blue => "hello"
    }
    return 0
}
