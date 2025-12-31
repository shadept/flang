//! TEST: generic_return_with_match
//! EXIT: 42

enum Option(T) {
    Some(T)
    None
}

// Test: generic function with match expression that returns literals
pub fn main() i32 {
    let opt: Option(i32) = Option.Some(42)
    let result = unwrap_or(opt, 0)
    return result
}

// Generic function with match expression returning literals
fn unwrap_or(opt: Option($T), default: T) T {
    return opt match {
        Some(value) => value,
        None => default
    }
}
