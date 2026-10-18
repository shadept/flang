//! TEST: callable_bound_op_call
//! EXIT: 30

type Scale = struct {
    k: i32
}

fn op_call(self: &Scale, x: i32) i32 {
    return self.k * x
}

fn apply(x: i32, f: $F) i32 where F: fn(i32) i32 {
    return f(x)
}

pub fn main() i32 {
    const base: i32 = 4
    const add = { x: i32 => x + base }
    return apply(5, Scale { k = 2 }) + apply(16, add)
}
