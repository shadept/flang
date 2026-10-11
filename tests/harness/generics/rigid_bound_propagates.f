//! TEST: rigid_bound_propagates
//! COMPILE-ERROR: E2134
//! EXIT: 1

fn dup(x: $T) (T, T) where T: copyable {
    return (x, x)
}

// Calling a function that requires `T: copyable` passes the requirement on: an unbounded caller is
// refused at the call, before anything instantiates it.
fn relay(x: $T) (T, T) {
    return dup(x) // error E2134
}

pub fn main() i32 {
    return 0
}
