//! TEST: labeled_unused
//! COMPILE-WARNING: W1005 label `outer` is never used
//! EXIT: 3

pub fn main() i32 {
    let n: i32 = 0
    outer: for _i in 0..3 as i32 {
        n = n + 1
    }
    return n
}
