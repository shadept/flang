//! TEST: iterator_error_next_wrong_return
//! COMPILE-ERROR: E2025

struct BadIterator {
    value: i32
}

fn iter(x: &BadIterator) BadIterator {
    return x.*
}

fn next(x: &BadIterator) i32 {  // Should return i32?, not i32
    return x.value
}

pub fn main() i32 {
    let x: BadIterator = .{ value = 42 }
    for (i in x) {
        return i
    }
    return 0
}
