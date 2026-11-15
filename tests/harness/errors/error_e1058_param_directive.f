//! TEST: error_e1058_param_directive
//! COMPILE-ERROR: E1058

// A parameter takes only `#it(name)`.
fn apply(#inline f: fn(i32) i32) i32 { // error[E1058]
    return f(1)
}

pub fn main() i32 {
    return apply { it }
}
