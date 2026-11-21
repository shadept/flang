//! TEST: array_decay_at_every_slot
//! EXIT: 0

// An array literal flowing into a slice slot decays to a `{ptr, len}` view wherever the slot is.
// Each position sets its own exit bit when it reads the wrong length: 1 struct-literal field, 2 a
// local reassigned, 4 assigned through a reference, 8 an if branch, 16 a return, 32 a match arm,
// 64 a non-empty literal reassigned. The stack is dirtied first so a missing store shows.

type Holder = struct {
    tag: i64
    xs: i64[]
}

fn dirty() i64 {
    let junk = [7i64; 64]
    let t: i64 = 0
    for i in 0..64 {
        t = t + junk[i]
    }
    return t
}

fn in_literal(tag: i64) Holder {
    return Holder { tag = tag, xs = [] }
}

fn reassigned(full: i64[]) i64[] {
    let xs = full
    xs = []
    return xs
}

fn reset(h: &Holder) {
    h.xs = []
}

fn branch(empty: bool, keep: i64[]) i64[] {
    return if empty { [] } else { keep }
}

fn returned() i64[] {
    return []
}

fn arm(n: i32, keep: i64[]) i64[] {
    return n match {
        0 => []
        _ => keep
    }
}

fn refilled(full: i64[]) i64[] {
    let xs = full
    xs = [4i64, 5]
    return xs
}

fn check(len: usize, want: usize, mask: i32) i32 {
    if len == want {
        return 0
    }
    return mask
}

pub fn main() i32 {
    let backing = [1i64, 2, 3]
    const full: i64[] = backing

    let failed: i32 = 0
    failed = failed | check(in_literal(dirty()).xs.len, 0, 1)

    const d = dirty()
    failed = failed | check(reassigned(full).len, 0, 2)

    let h = Holder { tag = d, xs = full }
    const _d2 = dirty()
    reset(&h)
    failed = failed | check(h.xs.len, 0, 4)

    const _d3 = dirty()
    failed = failed | check(branch(true, full).len, 0, 8)
    const _d4 = dirty()
    failed = failed | check(returned().len, 0, 16)
    const _d5 = dirty()
    failed = failed | check(arm(0, full).len, 0, 32)
    const _d6 = dirty()
    failed = failed | check(refilled(full).len, 2, 64)
    return failed
}
