//! TEST: anon_struct_fn_field
//! EXIT: 7

fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    let ops: struct { compute: fn(i32, i32) i32 } = .{ compute = add }
    return ops.compute(3, 4)
}
