//! TEST: match_error_non_exhaustive
//! COMPILE-ERROR: E2031

enum Value {
    None
    Some(i32)
    Error(i32)
}

pub fn main() i32 {
    let v: Value = Value.Some(5)
    
    // Error: Missing Error variant, no else clause
    return v match {
        None => 0,
        Some(x) => x
    }
}

