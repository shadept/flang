//! TEST: struct_slice_field_init
//! SKIP: Array-to-slice coercion not emitted in struct field initializers (C codegen bug)
//! EXIT: 5

// Assigning a [T; N] array directly to a T[] slice field in a struct literal
// passes type checking but fails at C codegen — the coercion is not emitted.
// See docs/known-issues.md: "Array-to-Slice Coercion in Struct Construction"

struct Wrapper {
    data: u8[],
    pos: usize
}

pub fn main() i32 {
    let arr: [u8; 5] = [1, 2, 3, 4, 5]
    let w = Wrapper { data = arr, pos = 0 }
    let n: usize = w.data.len
    return n as i32
}
