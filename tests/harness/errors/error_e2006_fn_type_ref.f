//! TEST: fn_type_ref_error
//! COMPILE-ERROR: E2006

// References to function types are disallowed - function types are already pointer-sized

fn foo(x: i32) i32 {
    return x
}

pub fn main() i32 {
    // ERROR: cannot create reference to function type
    let f: &fn(i32) i32 = foo
    return 0
}
