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

// TODO(tuple-opcmp): generic `op_cmp(a: ($T1, $T2, ...), ...)` overloads are not
// provided yet. The inference engine currently mishandles TypeVars embedded in the
// fields of anonymous tuple types at call sites that pass through enum variant
// constructors (see conv.f regression). Users needing ordered tuples must define
// `op_cmp` on their concrete tuple type until this is resolved, e.g.
// `fn op_cmp(a: (i32, String), b: (i32, String)) Ord { ... }`.
