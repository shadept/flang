//! TEST: closure_capture_address
//! EXIT: 7

fn set(p: &i32, v: i32) {
    p.* = v
}

// `&k` inside the body addresses the outer binding.
pub fn main() i32 {
    let k = 0
    let f = fn() { set(&k, 7) }
    f()
    return k
}
