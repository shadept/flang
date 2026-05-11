//! TEST: closure_passed_to_generic
//! EXIT: 50

// Capturing closure passed to a generic higher-order function. The HOF's
// callable parameter is generic ($F), so the closure travels by value with
// its anonymous type. apply dispatches via op_call on F.

fn apply(f: $F, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    let bias = 40
    return apply(fn(x: i32) i32 { x + bias }, 10)
}
