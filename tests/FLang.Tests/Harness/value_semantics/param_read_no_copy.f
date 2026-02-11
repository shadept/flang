//! TEST: param_read_no_copy
//! EXIT: 0

// When a function only reads a parameter (no writes), no copy should
// be needed (no COW triggered). This tests that read-only access
// through implicit reference works correctly for various types.

struct Big {
    a: i32,
    b: i32,
    c: i32
}

fn sum_fields(b: Big) i32 {
    b.a + b.b + b.c    // read-only access through implicit ref
}

fn first(b: Big) i32 {
    b.a
}

fn last(b: Big) i32 {
    b.c
}

pub fn main() i32 {
    let data = Big { a = 10, b = 20, c = 30 }

    if sum_fields(data) != 60 { return 1 }
    if first(data) != 10 { return 2 }
    if last(data) != 30 { return 3 }

    // Call multiple times — must be consistent
    if sum_fields(data) != 60 { return 4 }

    return 0
}
