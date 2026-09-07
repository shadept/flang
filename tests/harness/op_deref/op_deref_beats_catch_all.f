//! TEST: op_deref_beats_catch_all
//! EXIT: 0

// An overload that names the `op_deref` target's type is more specific than an unconstrained `$I`
// catch-all, even though only the catch-all matches the wrapper directly. `w.which()` must reach
// `which(&Inner)` through the peel rather than stop at `which($I)`; today the peel only runs when
// direct resolution fails, and the catch-all makes it succeed (docs/known-issues.md).

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
    if w.which() != 1 {
        return 1
    }

    let b: Box(Inner) = Box(Inner) { pad = 0, inner = Inner { value = 3 } }
    if b.which() != 1 {
        return 2
    }

    // The catch-all still wins when nothing peels to `Inner`.
    if which(3i64) != 2 {
        return 3
    }
    return 0
}
