//! TEST: closure_capture_generic_fn_param
//! EXIT: 0

// A lambda inside a generic fn body capturing the `$F`-typed parameter and
// calling it. Exercised per-specialization: once with a bare fn value
// (fn-pointer field call) and once with a capturing closure (op_call field
// dispatch).

fn apply(f: $F, x: i32) i32 { return f(x) }

fn with_key(key: $F, x: i32) i32 {
    let inner = fn(v: i32) i32 { key(v) + 100 }
    return apply(inner, x)
}

pub fn main() i32 {
    if with_key(fn(x: i32) i32 { x * 3 }, 4) != 112 { return 1 }

    let off = 7
    if with_key(fn(x: i32) i32 { x + off }, 4) != 111 { return 2 }

    return 0
}
