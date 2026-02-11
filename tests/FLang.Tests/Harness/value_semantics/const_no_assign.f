//! TEST: const_no_assign
//! COMPILE-ERROR: E2038

// const bindings cannot be reassigned.

pub fn main() i32 {
    const x = 10
    x = 20
    return x
}
