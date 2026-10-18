//! TEST: fn_type_closure_value
//! EXIT: 42

// A capturing closure held in a local, an annotated binding and a struct field converts to the
// `fn` type each slot names (RFC-037).

type Handler = struct {
    on: fn(i32) i32
}

fn apply(x: i32, f: fn(i32) i32) i32 {
    return f(x)
}

pub fn main() i32 {
    let k: i32 = 3
    let g = { v: i32 => v * k }
    let h: fn(i32) i32 = { v: i32 => v - k }
    const s: Handler = Handler { on = { v: i32 => v + k } }
    return apply(10, g) + h(10) + s.on(2)
}
