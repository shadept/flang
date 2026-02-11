//! TEST: nested_struct_copy
//! EXIT: 0

// Nested structs: assignment copies the entire structure (shallow).
// Inner struct is copied by value, not aliased.

struct Inner {
    val: i32
}

struct Outer {
    a: Inner,
    b: Inner
}

pub fn main() i32 {
    let x = Outer {
        a = Inner { val = 1 },
        b = Inner { val = 2 }
    }
    let y = x              // shallow copy of entire Outer

    y.a.val = 100          // mutate y's copy of Inner
    y.b.val = 200

    // x must be unchanged (Inner was copied, not aliased)
    if x.a.val != 1 { return 1 }
    if x.b.val != 2 { return 2 }

    // y reflects changes
    if y.a.val != 100 { return 3 }
    if y.b.val != 200 { return 4 }

    return 0
}
