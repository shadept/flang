//! TEST: op_deref_arg_as_written_wins
//! EXIT: 12

type Inner = struct {
    n: i32
}

type Wrap = struct {
    inner: Inner
}

fn op_deref(self: &Wrap) &Inner {
    return &self.inner
}

pub fn take(i: Inner) i32 {
    return 1
}

pub fn take(w: Wrap) i32 {
    return 10
}

pub fn take(x: $T) i32 {
    return 100
}

// The peel is a fallback: an overload taking the argument as written wins, and a catch-all as
// written wins over a concrete one through a hop.
pub fn main() i32 {
    const w = Wrap { inner = Inner { n = 0 } }
    const i = Inner { n = 0 }
    return take(w) + take(i) + 1
}
