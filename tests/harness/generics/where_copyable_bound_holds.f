//! TEST: where_copyable_bound_holds
//! EXIT: 7

// `where T: copyable` states that a body copies `T`; a copyable argument satisfies it.
fn dup(x: $T) (T, T) where T: copyable {
    return (x, x)
}

fn twice(x: $T) T where T: copyable {
    let a = x
    return a
}

fn touch(x: $T) where T: copyable {
    let _b = x
}

pub fn main() i32 {
    const p = dup(3i32)
    touch(p)
    return p.0 + p.1 + twice(1i32)
}
