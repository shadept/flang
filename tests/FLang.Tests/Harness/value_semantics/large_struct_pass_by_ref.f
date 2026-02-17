//! TEST: large_struct_pass_by_ref
//! EXIT: 0

// Large structs (>8 bytes) are passed by implicit reference.
// The caller's value must still be unaffected by callee reads.

type BigData = struct {
    a: i32,
    b: i32,
    c: i32,
    d: i32
}

fn sum(d: BigData) i32 {
    d.a + d.b + d.c + d.d
}

fn double_first(d: BigData) i32 {
    d.a * 2
}

pub fn main() i32 {
    let data = BigData { a = 1, b = 2, c = 3, d = 4 }

    // Multiple reads through implicit reference must be consistent
    let s1 = sum(data)
    let s2 = sum(data)
    if s1 != 10 { return 1 }
    if s2 != 10 { return 2 }

    // Reading a field through by-ref must work
    if double_first(data) != 2 { return 3 }

    // Original must be intact
    if data.a != 1 { return 4 }
    if data.d != 4 { return 5 }

    return 0
}
