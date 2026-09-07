//! TEST: op_deref_ref_receiver
//! EXIT: 0
//! STDOUT: 7
//! STDOUT: 7
//! STDOUT: 7
//! STDOUT: 7

// Member access and UFCS through `op_deref` when the receiver is a REFERENCE - a `&Wrap` parameter,
// plain or generic. The first hop takes the wrapper's address, and a reference already holds that
// address: the lowering has to load it, not hand the hop the parameter's own stack slot.

import std.io.print

type Inner = struct {
    tag: i64
    value: i64
}

type Wrap = struct {
    pad: i64
    inner: Inner
}

fn op_deref(w: &Wrap) &Inner {
    return &w.inner
}

fn value_of(i: &Inner) i64 {
    return i.value
}

fn by_ref(w: &Wrap) i64 {
    return w.value
}

fn by_ref_ufcs(w: &Wrap) i64 {
    return w.value_of()
}

type Box = struct(T) {
    pad: i64
    v: T
}

fn op_deref(b: &Box($T)) &T {
    return &b.v
}

fn generic_by_ref(b: &Box($T)) i64 {
    return b.value
}

pub fn main() i32 {
    let w = Wrap { pad = 1, inner = Inner { tag = 2, value = 7 } }
    println(w.value)
    println(by_ref(&w))
    println(by_ref_ufcs(&w))
    let b = Box (Inner) { pad = 3, v = Inner { tag = 4, value = 7 } }
    println(generic_by_ref(&b))
    return 0
}
