//! TEST: closure_capture_int
//! EXIT: 14

// Single i32 captured by reference. The closure literal synthesizes an anonymous
// struct holding `&k` and an `op_call` body that reads through `self.k`.

pub fn main() i32 {
    let k = 7
    let f = { x: i32 => x * k }
    return f(2)
}
