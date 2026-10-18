//! TEST: error_e1054_return_in_lambda
//! COMPILE-ERROR: E1054

// A lambda's value is its body's last expression; `return` inside one is refused (RFC-039).
fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply({ x: i32 => return x * 2 }, 21)
}
