//! TEST: closure_capture_in_if_block
//! EXIT: 21

// Closure declared inside a nested block (if-arm). Capture analysis must walk
// past intervening scopes that aren't lambda boundaries.

pub fn main() i32 {
    let base = 7
    let pick = true
    if pick {
        let f = fn(x: i32) i32 { x * base }
        return f(3)
    } else {
        return 0
    }
}
