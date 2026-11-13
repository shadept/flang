//! TEST: labeled_shadow
//! COMPILE-ERROR: E1056 label `outer` is already used by an enclosing loop
//! EXIT: 1

pub fn main() i32 {
    outer: for _i in 0..3 as i32 {
        outer: for _j in 0..3 as i32 {
            break outer
        }
    }
    return 0
}
