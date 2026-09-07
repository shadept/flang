//! TEST: op_deref_beats_iter_catch_all
//! EXIT: 0

// The same ranking against std.iter's real catch-alls: `last(it: $I)` and `any(it: $I, pred: $F)`
// are in scope wherever std.iter is imported, and they match any receiver. A wrapper whose
// `op_deref` target defines `last` and `any` must reach those, not the iterator versions - the
// managed collections (`List`, `Dict`) are exactly this shape, and `Dict`'s entry-wise `any` takes
// `(key, value)` where the catch-all would pass one item.

import std.collections.iter
import std.option

type Inner = struct {
    value: i64
}

type Wrap = struct {
    pad: i64
    inner: Inner
}

fn op_deref(w: &Wrap) &Inner {
    return &w.inner
}

fn last(x: &Inner) i64? {
    return Some(x.value)
}

fn any(x: &Inner, pred: $F) bool {
    return pred(x.value, x.value)
}

pub fn main() i32 {
    let w = Wrap { pad = 0, inner = Inner { value = 3 } }
    if w.last().unwrap_or(0) != 3 {
        return 1
    }
    if !w.any(fn(a, b) { a == b }) {
        return 2
    }
    return 0
}
