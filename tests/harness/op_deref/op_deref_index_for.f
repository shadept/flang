//! TEST: op_deref_index_for
//! EXIT: 21

// Indexing, index assignment and `for` on a wrapper resolve through `op_deref` exactly as the calls
// they desugar to (`w.op_index_ref(i)`, `w.iter()`): the same hop chain, the same generated code.
// Pinned against the resolution that once stopped at the wrapper (E2028 / E2021).

import std.option

type Inner = struct {
    a: i64
    b: i64
    c: i64
}

fn op_index_ref(x: &Inner, i: usize) &i64 {
    if i == 0 {
        return &x.a
    }
    if i == 1 {
        return &x.b
    }
    return &x.c
}

type InnerIter = struct {
    x: &Inner
    i: usize
}

fn iter(x: &Inner) InnerIter {
    return .{ x = x, i = 0 }
}

fn next(it: &InnerIter) i64? {
    if it.i >= 3 {
        return null
    }
    it.i = it.i + 1
    return Some(it.x[it.i - 1])
}

fn sum(x: &Inner) i64 {
    return x.a + x.b + x.c
}

type Wrap = struct {
    tag: i64
    inner: Inner
}

fn op_deref(w: &Wrap) &Inner {
    return &w.inner
}

pub fn main() i32 {
    let w = Wrap { tag = 0, inner = Inner { a = 1, b = 2, c = 3 } }

    let s = w.sum() // 6, a method call through the peel
    let f = w.a // 1, a field read through the peel
    let v = w[1] // 2, op_index_ref(&Inner, usize) through the peel
    w[2] = 9 // the same operator as a place
    let t = 0i64
    for x in w { // iter(&Inner) through the peel: 1 + 2 + 9
        t = t + x
    }
    return (s + f + v + t) as i32
}
