//! TEST: error_e2163_it_name_slot
//! COMPILE-ERROR: E2163

// `#it(name)` needs a parameter an arrow-less lambda fills with one parameter.
fn combine(a: i32, b: i32, #it(x) f: fn(i32, i32) i32) i32 { // error[E2163]
    return f(a, b)
}

pub fn main() i32 {
    return combine(1, 2) { a, b => a + b }
}
