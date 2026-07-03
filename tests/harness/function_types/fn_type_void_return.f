//! TEST: fn_type_void_return
//! EXIT: 42

// Test function types with void return type
// Tests that 'void' is available as a built-in type

fn log_value(x: i32) void {
    // void function - does something but returns nothing
    let unused = x + 1
}

fn apply_void(f: fn(i32) void, x: i32) i32 {
    f(x)
    return x
}

pub fn main() i32 {
    let result = apply_void(log_value, 42)
    return result
}
