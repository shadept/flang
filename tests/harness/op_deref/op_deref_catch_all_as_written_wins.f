//! TEST: op_deref_catch_all_as_written_wins
//! EXIT: 0

// `op_deref` is a fallback: a catch-all that accepts the wrapper as written takes the call, and the
// overload naming the inner type is reached only when nothing matches the receiver itself. UFCS
// does not change which overload wins; `w.which()` resolves as `which(w)` or `which(&w)` would.

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

type Box = struct(T) {
    pad: i64
    inner: T
}

fn op_deref(b: &Box($T)) &T {
    return &b.inner
}

fn which(x: &Inner) i64 { return 1 }
fn which(x: $I) i64 { return 2 }

pub fn main() i32 {
    let w = Wrap { pad = 0, inner = Inner { value = 3 } }
    if w.which() != 2 {
        return 1
    }

    let b: Box(Inner) = Box(Inner) { pad = 0, inner = Inner { value = 3 } }
    if b.which() != 2 {
        return 2
    }

    // And on a plain value.
    if which(3i64) != 2 {
        return 3
    }
    return 0
}
