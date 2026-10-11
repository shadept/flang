//! TEST: struct_bound_unsatisfied
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

pub fn main() i32 {
    let ok: Table(i32) = .{ first = 3 }
    let bad: Table(Point) = .{ first = Point { x = 1 } } // error E2134: `Point` has no `key`
    return ok.first
}
