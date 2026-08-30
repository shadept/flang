//! TEST: param_copy_on_write
//! EXIT: 0
//! NO-COMPILE-WARNING: W2004

// RFC-026: a by-value aggregate parameter is bound to the caller's value. The shadow copy appears
// only when the body writes to it or lets its address escape, and address identity is what makes
// that observable from inside the language.

type S = struct { a: i64, b: i64, c: i64, d: i64 }

// Read-only: no copy, so the parameter's address IS the caller's.
#allow(W2004)
fn reads(self: S) usize {
    return &self as usize
}

#allow(W2004)
fn addr_of(p: &S) usize {
    return p as usize
}

// The address escapes into a callee, so the copy stays and the address differs.
fn escapes(self: S) usize {
    return addr_of(&self)
}

// A write is invisible to the caller, copy or no copy.
fn mutates(self: S) i64 {
    self.a = 99
    return self.a
}

#allow(W2004)
pub fn main() i32 {
    let s = S { a = 1, b = 2, c = 3, d = 4 }
    const here = &s as usize

    if reads(s) != here {
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
