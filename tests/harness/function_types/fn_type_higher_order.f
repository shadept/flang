//! TEST: fn_type_return_void
//! EXIT: 7

// Test function type with void return

fn add_seven(x: i32) i32 {
    return x + 7
}

fn call_fn(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return call_fn(add_seven, 0)
}
