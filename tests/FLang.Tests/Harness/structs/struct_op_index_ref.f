//! TEST: struct_op_index_ref
//! EXIT: 62

// Ref-form indexing: a single `op_index_ref(&Self, Idx) &T` covers
// read, write, and address-of contexts via `[]`.

pub type MyVec = struct {
    a: i32
    b: i32
    c: i32
}

pub fn op_index_ref(v: &MyVec, index: usize) &i32 {
    if index == 0 { return &v.a }
    if index == 1 { return &v.b }
    return &v.c
}

fn inc(n: &i32) {
    n.* = n.* + 1
}

pub fn main() i32 {
    let v: MyVec = .{ a = 0, b = 0, c = 0 }

    // Write — desugars to `*op_index_ref(&v, 0) = 10`.
    v[0usize] = 10i32
    v[1usize] = 20i32
    v[2usize] = 30i32

    // Address-of — returns the raw pointer from op_index_ref; no copy.
    inc(&v[0usize])
    inc(&v[1usize])

    // Read — desugars to `*op_index_ref(&v, i)`.
    return v[0usize] + v[1usize] + v[2usize]
}
