//! TEST: while_false
//! EXIT: 7

// While with false condition: body never runs.
pub fn main() i32 {
    let n: i32 = 7
    while n > 100 {
        n = 0
    }
    return n
}
