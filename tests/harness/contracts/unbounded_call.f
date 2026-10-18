//! TEST: unbounded_call
//! COMPILE-ERROR: E2146
//! EXIT: 1

// `f` is called, but nothing says `F` is callable or with what.
fn apply(x: i32, f: $F) i32 {
    return f(x) // error E2146
}

// A bound by shape fixes it.
fn apply_bounded(x: i32, f: $F) i32 where F: fn(i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(1) { v => v } + apply_bounded(1) { v => v }
}
