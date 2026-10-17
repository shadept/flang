//! TEST: context_fn_value
//! EXIT: 11

// A call through a fn value passes the caller's context.

context offset: i32 = 0

fn add(x: i32) i32 {
    return x + context.offset
}

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    const f: fn(i32) i32 = add
    return context(offset = 10i32) { apply(f, 1i32) }
}
