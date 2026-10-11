//! TEST: rigid_copy_refused
//! COMPILE-ERROR: E2124
//! EXIT: 1

// A generic body is checked against its own type parameter, which is not copyable unless the
// signature says so: the copy is refused at the declaration, with no instantiation anywhere.
fn twice(x: $T) (T, T) {
    let a = x // error E2124
    return (a, a)
}

pub fn main() i32 {
    return 0
}
