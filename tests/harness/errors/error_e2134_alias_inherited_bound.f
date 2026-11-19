//! TEST: error_e2134_alias_inherited_bound
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Scored = contract {
    fn score(self: &Self) i64
}

type Board(T: Scored) = struct {
    item: T
}

// The aliased type's bound applies through the alias.
type Shelf(T) = Board(T)

pub fn main() i32 {
    const s: Shelf(i32) = .{ item = 1 } // error E2134
    return 0
}
