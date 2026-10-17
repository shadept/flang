//! TEST: context_rebind_value
//! EXIT: 30

// A rebind is an expression: its value is the body's, scalar or aggregate.

context scale: i32 = 1

type Pair = struct {
    a: i32
    b: i32
}

fn scaled(x: i32) i32 {
    return x * context.scale
}

fn pair() Pair {
    return Pair { a = scaled(1), b = scaled(2) }
}

pub fn main() i32 {
    const v: i32 = context(scale = 10i32) { scaled(1) }
    const p: Pair = context(scale = 5i32) { pair() }
    return v + p.a + p.b + scaled(5)
}
