//! TEST: error_e2049_missing_return
//! COMPILE-ERROR: E2049

pub fn compute(x: i32) i32 {
    let y = x + 1
}

pub fn main() {
    compute(5)
}
