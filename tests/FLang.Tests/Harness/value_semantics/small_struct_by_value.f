//! TEST: small_struct_by_value
//! EXIT: 0

// Small structs (<= 8 bytes) are passed/returned by value (register).
// Mutations in callee must not affect caller.

struct Pair {
    x: i32,
    y: i32
}

fn swap(p: Pair) Pair {
    let tmp = p.x
    p.x = p.y
    p.y = tmp
    p
}

pub fn main() i32 {
    let original = Pair { x = 10, y = 20 }
    let swapped = swap(original)

    // Original must be unchanged
    if original.x != 10 { return 1 }
    if original.y != 20 { return 2 }

    // Swapped must reflect the swap
    if swapped.x != 20 { return 3 }
    if swapped.y != 10 { return 4 }

    return 0
}
