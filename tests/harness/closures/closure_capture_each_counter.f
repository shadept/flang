//! TEST: closure_capture_each_counter
//! EXIT: 3

// The RFC-033 shape: a combinator calls back a closure that counts into the caller's local.
pub fn main() i32 {
    let values: [i32; 3] = [4, 5, 6]
    let s: i32[] = values
    let c: usize = 0
    s.each { v => c = c + 1 }
    return c as i32
}
