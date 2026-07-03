//! TEST: ufcs_generic
//! EXIT: 42

// Generic function with reference parameter for UFCS
fn identity(x: &$T) T {
    return x.*
}

pub fn main() i32 {
    let n: i32 = 42
    // UFCS with generic function: n.identity() -> identity(&n)
    return n.identity()
}
