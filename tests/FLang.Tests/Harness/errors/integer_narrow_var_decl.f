//! TEST: integer_narrow_var_decl
//! COMPILE-ERROR: E2002
//! EXIT: 1

// Narrowing in a variable declaration must be rejected — there is no
// implicit narrowing coercion. Today the compiler silently accepts this
// because the bidirectional coercion infrastructure applies the widening
// rule "backwards" (treating the i64 literal as if it were the i32 slot).

pub fn main() i32 {
    let x: i32 = 5i64   // narrowing i64 -> i32 must error
    return x
}
