//! TEST: error_e1006_break_in_lambda
//! COMPILE-ERROR: E1006

// A lambda body is outside every enclosing loop: `break` there has no loop to act on.
fn run(f: fn()) {
    f()
}

pub fn main() i32 {
    for i in 0..3 {
        run { => break }
    }
    return 0
}
