//! TEST: op_error_no_impl
//! COMPILE-ERROR: E2017

// Test that using an operator on a struct without op_* function produces an error

struct NoOps {
    val: i32
}

pub fn main() i32 {
    let a: NoOps = NoOps { val = 1 }
    let b: NoOps = NoOps { val = 2 }

    // No op_add is defined for NoOps - should produce E2017
    let c: NoOps = a + b

    return 0
}
