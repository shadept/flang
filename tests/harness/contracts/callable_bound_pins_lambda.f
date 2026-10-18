//! TEST: callable_bound_pins_lambda
//! EXIT: 42

type Meters = struct {
    v: i32
}

type Feet = struct {
    v: i32
}

fn amount(m: Meters) i32 {
    return m.v
}

fn amount(f: Feet) i32 {
    return f.v * 3
}

// Without the bound, `x.amount()` in the lambda has two candidates and an open receiver; `F: fn(T)
// i32` gives `x` its type before the call is resolved.
fn apply(x: $T, f: $F) i32 where F: fn(T) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(Feet { v = 14 }) { x => x.amount() }
}
