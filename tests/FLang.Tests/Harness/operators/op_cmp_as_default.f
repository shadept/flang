//! TEST: op_cmp_as_default
//! EXIT: 0

pub fn my_min(a: $T, b: T) T {
    return if op_cmp(a, b) == Ord.Less { a } else { b }
}

pub fn my_min(a: $T, b: T, comparator: fn(T, T) Ord) T {
    return if comparator(a, b) == Ord.Less { a } else { b }
}

fn reverse_i32(a: i32, b: i32) Ord {
    return op_cmp(b, a)
}

pub fn main() i32 {
    const m = my_min(5i32, 3i32)
    if m != 3i32 { return 1 }
    const m2 = my_min(5i32, 3i32, reverse_i32)
    if m2 != 5i32 { return 2 }
    return 0
}
