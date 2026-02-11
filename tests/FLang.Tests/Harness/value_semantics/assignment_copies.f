//! TEST: assignment_copies
//! EXIT: 0
//! STDOUT: 10
//! STDOUT: 42

// Assignment is a shallow byte-copy. Both variables exist independently.

struct Pair {
    a: i32,
    b: i32
}

pub fn main() i32 {
    let x = Pair { a = 10, b = 20 }
    let y = x          // shallow copy
    y.a = 42            // mutate y — must NOT affect x

    println(x.a)          // should still be 10
    println(y.a)          // should be 42

    if x.a != 10 { return 1 }
    if y.a != 42 { return 2 }
    if x.b != 20 { return 3 }
    if y.b != 20 { return 4 }
    return 0
}
