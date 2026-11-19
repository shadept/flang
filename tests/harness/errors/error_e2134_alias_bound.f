//! TEST: error_e2134_alias_bound
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Scored = contract {
    fn score(self: &Self) i64
}

type Medal = struct {
    owned v: i64
}

fn score(self: &Medal) i64 {
    return self.v
}

pub fn deinit(self: move Medal) {}

type Board(T: Scored) = struct {
    item: T
}

// A bound on the alias adds to the aliased type's: `Medal` is `Scored` but not copyable.
type Twin(T: copyable) = Board(T)

pub fn main() i32 {
    const t: Twin(Medal) = .{ item = Medal { v = 1 } } // error E2134
    return 0
}
