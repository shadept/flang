//! TEST: app_bound_at_instantiation
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Keyed = contract {
    fn key(self: Self) i32
}

fn key(self: i32) i32 {
    return self
}

type Table = struct(K: Keyed) {
    first: K
}

type Point = struct {
    x: i32
}

// `Table(T)` is written with `T` open: its bound waits for the instantiation that settles `T`.
fn first_of(x: $T) i32 where T: copyable {
    let t: Table(T) = .{ first = x }
    return 0
}

pub fn main() i32 {
    const ok = first_of(3i32)
    return first_of(Point { x = 1 }) // error E2134: `Point` has no `key`
}
