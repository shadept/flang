//! TEST: param_copy_on_write
//! EXIT: 0
//! NO-COMPILE-WARNING: W2004

// RFC-026: a by-value aggregate parameter is bound to the caller's value, and the shadow copy
// appears only when the body writes to it or lets its address escape.
//
// What this file pins is the *semantics* that hold either way: a write through the parameter never
// reaches the caller, and a parameter whose address escapes is a copy the callee cannot use to
// reach back. The elision itself is pinned in `lower.f`, by the `memcpy_count` tests around
// "an aggregate parameter arrives by pointer".
//
// It deliberately makes no claim about address identity for a read-only parameter. RFC-026 §3
// envisaged `reads(s) == (&s as usize)` as the observable guarantee, but the analysis that landed
// is an AST whitelist (`param_escape.f`), and `&self` is an `AddressOf` - a form the whitelist
// refuses, so the copy stays. Under these semantics elision is not observable from inside the
// language, and asserting either direction here would pin a conservatism the whitelist is free to
// relax later.

type S = struct { a: i64, b: i64, c: i64, d: i64 }

#allow(W2004)
fn addr_of(p: &S) usize {
    return p as usize
}

// The address escapes into a callee, so the copy stays and the callee sees different storage.
fn escapes(self: S) usize {
    return addr_of(&self)
}

// A write is invisible to the caller, copy or no copy.
fn mutates(self: S) i64 {
    self.a = 99
    return self.a
}

// Reading a field never needs the parameter's own bytes.
fn reads_field(self: S) i64 {
    return self.a
}

#allow(W2004)
pub fn main() i32 {
    let s = S { a = 1, b = 2, c = 3, d = 4 }
    const here = &s as usize

    if reads_field(s) != 1 {
        return 1
    }
    if escapes(s) == here {
        return 2
    }
    if mutates(s) != 99 {
        return 3
    }
    if s.a != 1 {
        return 4
    }
    return 0
}
