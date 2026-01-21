//! TEST: fn_type_void_in_struct
//! EXIT: 10

// Test void return type in function type within struct field
// This matches the original bug report: Allocator { free: fn(...) void }

struct Handler {
    process: fn(i32) void,
    get_value: fn() i32
}

fn my_process(x: i32) void {
    let unused = x * 2
}

fn my_get_value() i32 {
    return 10
}

pub fn main() i32 {
    let h = Handler { process = my_process, get_value = my_get_value }
    h.process(5)
    return h.get_value()
}
