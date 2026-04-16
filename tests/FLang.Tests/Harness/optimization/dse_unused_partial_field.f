//! TEST: dse_unused_partial_field
//! EXIT: 77

// When only one field of a struct is read, the current (conservative) DSE
// keeps the whole alloca alive. The important invariant is correctness —
// the program must still produce the right answer.

type Pair = struct {
    a: i32,
    b: i32,
}

pub fn main() i32 {
    let p = Pair { a = 77, b = 99 }
    return p.a
}
