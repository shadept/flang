//! TEST: jump_takes_no_value
//! COMPILE-ERROR: E1002 `break` takes no value
//! EXIT: 1

pub fn main() i32 {
    outer: loop {
        break outer 3
    }
    return 0
}
