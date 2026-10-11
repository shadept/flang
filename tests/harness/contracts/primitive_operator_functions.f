//! TEST: primitive_operator_functions
//! EXIT: 0

// Every operator of a primitive is also a function (spec 5.2): calls, values and the operator
// agree.
fn apply(a: i32, b: i32, f: fn(i32, i32) i32) i32 {
    return f(a, b)
}

pub fn main() i32 {
    const a: i32 = 7
    if !op_eq(a, 7) or op_ne(a, 7) or !op_lt(a, 8) or !op_ge(a, 7) {
        return 1
    }
    if op_add(a, 3) != 10 or op_sub(a, 3) != 4 or op_mul(a, 3) != 21 or op_div(a, 2) != 3
        or op_mod(a, 4) != 3 {
        return 2
    }
    if op_neg(a) != -7 or op_bnot(0u8) != 255u8 or op_shl(1u32, 4u32) != 16u32 or op_band(6i32,
        3i32) != 2 or op_bxor(6i32, 3i32) != 5 {
        return 3
    }
    if !op_not(false) or op_band(true, false) or !op_lt('a', 'b') or op_add(1.5f64, 1.0f64) != 2.5 {
        return 4
    }
    if apply(a, 5, op_add) != 12 {
        return 5
    }
    return 0
}
