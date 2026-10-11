//! TEST: implied_bound_at_call
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Keyed = contract {
    fn key(self: Self) i32
}

type Table = struct(K: Keyed) {
    first: K
}

type Point = struct {
    x: i32
}

// The return type implies `T: Keyed`, checked where the call binds `T`.
fn single(x: move $T) Table(T) {
    return .{ first = move x }
}

pub fn main() i32 {
    let t = single(Point { x = 1 }) // error E2134: `Point` has no `key`
    return 0
}
