//! TEST: closure_no_capture
//! EXIT: 42

// Sanity: non-capturing `fn(...)` lambdas still type-check and lower as plain
// function pointers after the LambdaScopeBarrier is removed by RFC-014 Phase 2.

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(fn(x: i32) i32 { x * 2 }, 21)
}
