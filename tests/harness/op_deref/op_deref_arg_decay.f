//! TEST: op_deref_arg_decay
//! EXIT: 24

type Inner = struct {
    n: i32
}

type Wrap = struct {
    // A leading field, so the hop is a real offset rather than the same address.
    tag: i64
    inner: Inner
}

fn op_deref(self: &Wrap) &Inner {
    return &self.inner
}

type Outer = struct {
    tag: i64
    wrap: Wrap
}

fn op_deref(self: &Outer) &Wrap {
    return &self.wrap
}

// The value leg: an owner decays to the value it holds.
fn by_value(i: Inner) i32 {
    return i.n
}

// The reference leg: `&Wrap` reaches `&Inner` with no copy.
fn by_ref(i: &Inner) i32 {
    return i.n * 2
}

// An argument reaches its parameter through `op_deref`, spelled either way, one hop or several
// (RFC-020).
pub fn main() i32 {
    const w = Wrap { tag = 0, inner = Inner { n = 3 } }
    const o = Outer { tag = 0, wrap = Wrap { tag = 0, inner = Inner { n = 5 } } }
    return by_value(w) + by_ref(&w) + by_value(o) + by_ref(&o)
}
