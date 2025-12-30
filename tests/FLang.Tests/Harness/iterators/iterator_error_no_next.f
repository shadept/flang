//! TEST: iterator_error_no_next
//! COMPILE-ERROR: E2022

struct IncompleteIterator {
    value: i32
}

fn iter(x: &IncompleteIterator) IncompleteIterator {
    return *x
}

pub fn main() i32 {
    let x: IncompleteIterator = .{ value = 42 }
    for (i in x) {
        return i
    }
    return 0
}
