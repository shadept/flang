//! TEST: fn_type_closure_arg
//! EXIT: 42

// A capturing closure converts to a `fn` parameter (RFC-037): the callee is compiled once and
// calls it through the `{ code, env }` pair, reading and writing the captures in place.

fn apply(x: i32, f: fn(i32) i32) i32 {
    return f(x)
}

fn both(x: i32, a: fn(i32) i32, b: fn(i32) i32) i32 {
    return a(x) + b(x)
}

fn twice(x: i32) i32 {
    return x * 2
}

pub fn main() i32 {
    let off: i32 = 10
    let count: i32 = 0
    const a: i32 = apply(1) { v: i32 => v + off }
    const b: i32 = apply(1, { v: i32 => v + off })
    const c: i32 = both(3, twice) { v: i32 =>
        count = count + 1
        v
    }
    off = 20
    const d: i32 = apply(1) { v: i32 => v + off }
    return a + b + c + d + count - 11
}
