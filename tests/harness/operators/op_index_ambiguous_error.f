//! TEST: op_index_ambiguous_error
//! COMPILE-ERROR: E2077

// Declaring both ref-form `op_index_ref` and value-form `op_index` for the
// same (Self, Idx) pair is an error — the two patterns are mutually exclusive.

pub type MyVec = struct {
    a: i32
    b: i32
}

fn op_index(v: MyVec, i: usize) i32 {
    return v.a
}

fn op_index_ref(v: &MyVec, i: usize) &i32 {
    return &v.a
}

pub fn main() i32 {
    let v: MyVec = .{ a = 1, b = 2 }
    return v[0usize]
}
