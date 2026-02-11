//! TEST: let_reassign
//! EXIT: 0

// let bindings are mutable — reassignment is allowed.

pub fn main() i32 {
    let x: i32 = 10
    if x != 10 { return 1 }

    x = 20
    if x != 20 { return 2 }

    x = x + 5
    if x != 25 { return 3 }

    return 0
}
