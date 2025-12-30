//! TEST: iterator_error_next_wrong_return_struct
//! COMPILE-ERROR: E2025

struct BadIterator {
    value: i32
}

struct WrongReturn {
    val: i32
}

fn iter(x: &BadIterator) BadIterator {
    return x.*
}

fn next(x: &BadIterator) WrongReturn {  // Should return WrongReturn?, not WrongReturn
    return .{ val = x.value }
}

pub fn main() i32 {
    let x: BadIterator = .{ value = 42 }
    for (i in x) {
        return i.val
    }
    return 0
}

