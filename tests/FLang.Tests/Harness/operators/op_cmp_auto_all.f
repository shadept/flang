//! TEST: op_cmp_auto_all
//! EXIT: 6

// Test auto-deriving all comparison operators from op_cmp

enum Ord {
    Less = -1
    Equal = 0
    Greater = 1
}

struct Val {
    n: i32
}

pub fn op_cmp(lhs: Val, rhs: Val) Ord {
    return if (lhs.n < rhs.n) Ord.Less
        else if (lhs.n > rhs.n) Ord.Greater
        else Ord.Equal
}

fn check_lt(a: Val, b: Val) i32 {
    return if (a < b) 1 else 0
}

fn check_gt(a: Val, b: Val) i32 {
    return if (a > b) 1 else 0
}

fn check_le(a: Val, b: Val) i32 {
    return if (a <= b) 1 else 0
}

fn check_ge(a: Val, b: Val) i32 {
    return if (a >= b) 1 else 0
}

fn check_eq(a: Val, b: Val) i32 {
    return if (a == b) 1 else 0
}

fn check_ne(a: Val, b: Val) i32 {
    return if (a != b) 1 else 0
}

pub fn main() i32 {
    let a: Val = Val { n = 3 }
    let b: Val = Val { n = 7 }
    let c: Val = Val { n = 3 }

    // a < b => 1, a > b => 0, a <= c => 1, a >= c => 1, a == c => 1, a != b => 1
    // false cases: a > b => 0, b <= a => 0
    return check_lt(a, b) + check_le(a, c) + check_ge(a, c) + check_eq(a, c) + check_ne(a, b) + check_ge(b, a)
}
