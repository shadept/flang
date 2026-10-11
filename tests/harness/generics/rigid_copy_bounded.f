//! TEST: rigid_copy_bounded
//! EXIT: 6

// `where T: copyable` is what lets a generic body copy a `T`.
fn twice(x: $T) (T, T) where T: copyable {
    let a = x
    return (a, a)
}

pub fn main() i32 {
    const p = twice(3i32)
    return p.0 + p.1
}
