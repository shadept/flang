//! TEST: param_shadow_emitted_once
//! EXIT: 0
//! NO-COMPILE-WARNING: W2004

// RFC-026: taking a by-value aggregate parameter's address IS an escape, so the shadow copy stays.
// What this pins is that the shadow is emitted ONCE, in the prologue, and not once per escape: the
// parameter has exactly one storage location for the whole body, so every `&self` yields the same
// address - before a write, after a write, and across a call that takes the address.
//
// The FIR-level statement of the same invariant is the `memcpy_count(f) == 1` assertion in
// `lower.f`, "the shadow is emitted once, however many times the parameter escapes".

type S = struct { a: i64, b: i64, c: i64, d: i64 }

#allow(W2004)
fn addr_of(p: &S) usize {
    return p as usize
}

// Every address of `self` names the one shadow, so all four agree.
#allow(W2004)
fn all_addresses_agree(self: S) bool {
    const before: usize = &self as usize
    const again: usize = &self as usize
    const through_call: usize = addr_of(&self)
    // A write lands in that same shadow rather than creating a second one.
    self.a = 5
    const after_write: usize = &self as usize
    return before == again and again == through_call and through_call == after_write
}

pub fn main() i32 {
    let s = S { a = 1, b = 2, c = 3, d = 4 }
    if !all_addresses_agree(s) {
        return 1
    }
    // The write inside `all_addresses_agree` stayed in the shadow.
    if s.a != 1 {
        return 2
    }
    return 0
}
