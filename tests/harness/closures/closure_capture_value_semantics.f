//! TEST: closure_capture_value_semantics
//! EXIT: 5

// Captures are by value — the closure's `k` is a *copy* of the local at the
// literal site, so reassigning the outer `k` after construction must not
// change what the closure observes.

pub fn main() i32 {
    let k = 5
    let f = fn() i32 { k }
    k = 999
    return f()
}
