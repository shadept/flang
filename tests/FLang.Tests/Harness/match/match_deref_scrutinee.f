//! TEST: match_deref_scrutinee
//! EXIT: 42

// Test that matching on a dereferenced enum pointer works correctly.
// This exercises the fix for dangling pointers when `self.*` is the scrutinee:
// the match should use the original pointer for field access rather than
// copying to a local alloca that goes out of scope.

type Value = enum {
    Int(i32)
    Pair(i32, i32)
    None
}

fn get_int(v: &Value) i32 {
    return v.* match {
        Int(x) => x,
        Pair(a, b) => a + b,
        None => 0
    }
}

fn get_pair_sum(v: &Value) i32 {
    return v.* match {
        Int(x) => x,
        Pair(a, b) => a + b,
        None => -1
    }
}

pub fn main() i32 {
    let v1: Value = Value.Int(10)
    let v2: Value = Value.Pair(20, 12)
    let v3: Value = Value.None

    let r1 = get_int(&v1)
    if r1 != 10 { return 1 }

    let r2 = get_pair_sum(&v2)
    if r2 != 32 { return 2 }

    let r3 = get_int(&v3)
    if r3 != 0 { return 3 }

    // r1 + r2 = 10 + 32 = 42
    return r1 + r2
}
