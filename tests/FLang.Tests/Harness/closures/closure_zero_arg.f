//! TEST: closure_zero_arg
//! EXIT: 42

// Zero-argument capturing lambda — only the env struct, no extra params.

pub fn main() i32 {
    let answer = 42
    let fetch = fn() i32 { answer }
    return fetch()
}
