//! TEST: generic_return_simple
//! EXIT: 42

// Simplest test: generic function with known type and literal
pub fn main() i32 {
    let x: i32 = 100
    let result = pick_second(x, 42)
    return result
}

// Generic function that returns the second argument (the literal)
fn pick_second(a: $T, b: T) T {
    return b
}
