//! TEST: iterator_error_no_iter
//! COMPILE-ERROR: E2020

struct NoIterator {
    value: i32
}

pub fn main() i32 {
    let x: NoIterator = .{ value = 42 }
    for (i in x) {
        return i
    }
    return 0
}
