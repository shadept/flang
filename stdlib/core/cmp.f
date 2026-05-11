// Comparison primitives.
//
// Defines `Ord` — the total-order result type — and `op_cmp` overloads for
// all primitive types, plus tuples of arity 1–8. Together with the compiler's
// auto-derivation of `<`, `>`, `<=`, `>=`, `==`, `!=` from `op_cmp`, this lets
// user types become orderable by defining a single `op_cmp` function.
//
// For primitive types, `<`/`>`/`==` always use the hardware compare; the
// `op_cmp` overloads here exist so that primitives can be passed as the
// default comparator to generic algorithms (see `std.sort`).

// =============================================================================
// Types
// =============================================================================

// Total-order comparison result. Tag values are fixed: the compiler compares
// the tag against 0 when deriving `<`/`>`/`<=`/`>=` from `op_cmp`.
pub type Ord = enum {
    Less = -1
    Equal = 0
    Greater = 1
}

// Equality on Ord so `cmp(a, b) == Ord.Less` etc. works. `op_ne` auto-derives.
pub fn op_eq(a: Ord, b: Ord) bool {
    return a match {
        Less => b match { Less => true, else => false },
        Equal => b match { Equal => true, else => false },
        Greater => b match { Greater => true, else => false }
    }
}

// =============================================================================
// Primitive op_cmp
// =============================================================================

pub fn op_cmp(a: i8, b: i8) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: i16, b: i16) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: i32, b: i32) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: i64, b: i64) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: isize, b: isize) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: u8, b: u8) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: u16, b: u16) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: u32, b: u32) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: u64, b: u64) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: usize, b: usize) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

// NaN is not ordered by IEEE 754. Here, any NaN input yields `Ord.Equal`
// because both `<` and `>` return false for NaN. Sorting a slice containing
// NaN is therefore not well-defined — filter or replace NaNs beforehand.
pub fn op_cmp(a: f32, b: f32) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: f64, b: f64) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

pub fn op_cmp(a: bool, b: bool) Ord {
    if a == b { return Ord.Equal }
    if b { return Ord.Less }
    return Ord.Greater
}

pub fn op_cmp(a: char, b: char) Ord {
    if a < b { return Ord.Less }
    if a > b { return Ord.Greater }
    return Ord.Equal
}

// =============================================================================
// Tuple op_cmp (lexicographic, arity 1–8)
// =============================================================================

// Lexicographic comparison on tuples — `op_cmp` is auto-derived for `<`/`>`/`<=`/`>=`/`==`/`!=`,
// so user types containing tuples become orderable for free.
pub fn op_cmp(a: ($T,), b: (T,)) Ord {
    return op_cmp(a.0, b.0)
}

pub fn op_cmp(a: ($T1, $T2), b: (T1, T2)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    return op_cmp(a.1, b.1)
}

pub fn op_cmp(a: ($T1, $T2, $T3), b: (T1, T2, T3)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    return op_cmp(a.2, b.2)
}

pub fn op_cmp(a: ($T1, $T2, $T3, $T4), b: (T1, T2, T3, T4)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    const c2 = op_cmp(a.2, b.2)
    if c2 != Ord.Equal { return c2 }
    return op_cmp(a.3, b.3)
}

pub fn op_cmp(a: ($T1, $T2, $T3, $T4, $T5), b: (T1, T2, T3, T4, T5)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    const c2 = op_cmp(a.2, b.2)
    if c2 != Ord.Equal { return c2 }
    const c3 = op_cmp(a.3, b.3)
    if c3 != Ord.Equal { return c3 }
    return op_cmp(a.4, b.4)
}

pub fn op_cmp(a: ($T1, $T2, $T3, $T4, $T5, $T6), b: (T1, T2, T3, T4, T5, T6)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    const c2 = op_cmp(a.2, b.2)
    if c2 != Ord.Equal { return c2 }
    const c3 = op_cmp(a.3, b.3)
    if c3 != Ord.Equal { return c3 }
    const c4 = op_cmp(a.4, b.4)
    if c4 != Ord.Equal { return c4 }
    return op_cmp(a.5, b.5)
}

pub fn op_cmp(a: ($T1, $T2, $T3, $T4, $T5, $T6, $T7), b: (T1, T2, T3, T4, T5, T6, T7)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    const c2 = op_cmp(a.2, b.2)
    if c2 != Ord.Equal { return c2 }
    const c3 = op_cmp(a.3, b.3)
    if c3 != Ord.Equal { return c3 }
    const c4 = op_cmp(a.4, b.4)
    if c4 != Ord.Equal { return c4 }
    const c5 = op_cmp(a.5, b.5)
    if c5 != Ord.Equal { return c5 }
    return op_cmp(a.6, b.6)
}

pub fn op_cmp(a: ($T1, $T2, $T3, $T4, $T5, $T6, $T7, $T8), b: (T1, T2, T3, T4, T5, T6, T7, T8)) Ord {
    const c0 = op_cmp(a.0, b.0)
    if c0 != Ord.Equal { return c0 }
    const c1 = op_cmp(a.1, b.1)
    if c1 != Ord.Equal { return c1 }
    const c2 = op_cmp(a.2, b.2)
    if c2 != Ord.Equal { return c2 }
    const c3 = op_cmp(a.3, b.3)
    if c3 != Ord.Equal { return c3 }
    const c4 = op_cmp(a.4, b.4)
    if c4 != Ord.Equal { return c4 }
    const c5 = op_cmp(a.5, b.5)
    if c5 != Ord.Equal { return c5 }
    const c6 = op_cmp(a.6, b.6)
    if c6 != Ord.Equal { return c6 }
    return op_cmp(a.7, b.7)
}
