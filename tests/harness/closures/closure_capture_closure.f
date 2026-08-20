//! TEST: closure_capture_closure
//! EXIT: 30

// A closure capturing another (capturing) closure: the captured field is a
// __Closure_N struct, so the inner call dispatches through its op_call.

fn apply(f: $F, x: i32) i32 { return f(x) }

pub fn main() i32 {
    let base = 10
    let add_base = fn(x: i32) i32 { x + base }
    let wrapped = fn(x: i32) i32 { add_base(x) * 2 }
    return apply(wrapped, 5)
}
