//! TEST: closure_capture_param
//! EXIT: 15

// Capturing the enclosing function's parameter, not just a `let`-binding.

fn make_adder(base: i32, x: i32) i32 {
    let f = fn(y: i32) i32 { base + y }
    return f(x)
}

pub fn main() i32 {
    return make_adder(10, 5)
}
