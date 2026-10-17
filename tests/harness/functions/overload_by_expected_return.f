//! TEST: overload_by_expected_return
//! EXIT: 17

// Overloads that differ only in their return type: the annotated binding or the assigned slot
// picks, whichever was declared first.

type A = struct {
    a: i32
}

type B = struct {
    b: i32
}

fn make(n: i32) A {
    return A { a = n }
}

fn make(n: i32) B {
    return B { b = n * 2 }
}

pub fn main() i32 {
    const x: B = make(3)
    const y: A = make(1)
    let z = B { b = 0 }
    z = make(5)
    return x.b + y.a + z.b
}
