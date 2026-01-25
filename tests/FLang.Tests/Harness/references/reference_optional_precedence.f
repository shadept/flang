//! TEST: reference_optional_precedence
//! EXIT: 42
//! DESCRIPTION: Tests that &i32? parses as (&i32)? (optional reference) not &(i32?) (reference to optional)

import std.option

// Function returning optional reference: (&i32)?
pub fn get_ref_opt(ptr: &i32, has_value: bool) &i32? {
    if (has_value) {
        return ptr
    }
    return null
}

pub fn main() i32 {
    let x: i32 = 42
    let result: &i32? = get_ref_opt(&x, true)

    // Unwrap the optional to get the reference, then dereference
    let ptr = unwrap_or(&result, &x)
    return ptr.*
}
