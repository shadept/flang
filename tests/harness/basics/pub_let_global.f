//! TEST: pub_let_global
//! EXIT: 3

// A module-level `let` is a declaration like `const`; `pub` reaches it too.
pub let counter: i32 = 0

fn bump() {
    counter = counter + 1
}

pub fn main() i32 {
    bump()
    bump()
    bump()
    return counter
}
