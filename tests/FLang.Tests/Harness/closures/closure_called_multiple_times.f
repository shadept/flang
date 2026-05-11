//! TEST: closure_called_multiple_times
//! EXIT: 30

// Each invocation reads from the same captured snapshot. By-value capture
// means the closure carries its own `k`; multi-call works without aliasing.

pub fn main() i32 {
    let k = 10
    let f = fn() i32 { k }
    return f() + f() + f()
}
