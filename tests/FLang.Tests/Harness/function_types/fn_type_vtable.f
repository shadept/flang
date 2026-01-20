//! TEST: fn_type_vtable
//! EXIT: 35

// Test struct containing function pointers (vtable pattern)
// Uses direct field-call syntax: ops.add(5, 3)

struct Operations {
    add: fn(i32, i32) i32,
    mul: fn(i32, i32) i32
}

fn my_add(a: i32, b: i32) i32 {
    return a + b
}

fn my_mul(a: i32, b: i32) i32 {
    return a * b
}

pub fn main() i32 {
    let ops = Operations { add = my_add, mul = my_mul }
    // Direct field-call syntax: field access + call in one expression
    let sum = ops.add(5, 3)    // 8
    let prod = ops.mul(5, 3)   // 15
    let sum2 = ops.add(2, 10)  // 12
    return sum + prod + sum2   // 8 + 15 + 12 = 35
}
