//! TEST: labeled_not_loop
//! COMPILE-ERROR: E1057
//! EXIT: 1

// Only `for`, `while` and `loop` take a label, and only on the same line.
pub fn main() i32 {
    let n: i32 = 0
    block: if n == 0 {
        n = 1
    }
    split:
    loop {
        break
    }
    return n
}
