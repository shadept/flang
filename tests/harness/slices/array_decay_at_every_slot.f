//! TEST: array_decay_at_every_slot
//! EXIT: 0

// An array literal flowing into a slice slot decays to a `{ptr, len}` view wherever the slot is.
// Each position is numbered, and the test exits with the number of the first one that reads the
// wrong length. The stack is dirtied first so a missing store shows.

import std.option

type Holder = struct {
    tag: i64
    xs: i64[]
}

type Carrier = enum {
    Full(i64[])
    Empty
}

const TABLE: i64[] = [1i64, 2, 3, 4]

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

fn payload_len(c: Carrier) usize {
    return c match {
        Full(xs) => xs.len
        Empty => 99
    }
}

fn defaulted(xs: i64[] = [1i64, 2, 3]) usize {
    return xs.len
}

fn produced_len(f: fn() i64[]) usize {
    const _d = dirty()
    return f().len
}

fn count(xs: i64[]) usize {
    return xs.len
}

fn check(len: usize, want: usize, position: i32) i32 {
    if len == want {
        return 0
    }
    return position
}

// The first nonzero position, so the exit code names the slot that failed.
fn first(failed: i32, next: i32) i32 {
    if failed != 0 {
        return failed
    }
    return next
}

pub fn main() i32 {
    let backing = [1i64, 2, 3]
    const full: i64[] = backing

    let failed: i32 = 0
    failed = first(failed, check(in_literal(dirty()).xs.len, 0, 1))

    const d = dirty()
    failed = first(failed, check(reassigned(full).len, 0, 2))

    let h = Holder { tag = d, xs = full }
    const _d2 = dirty()
    reset(&h)
    failed = first(failed, check(h.xs.len, 0, 3))

    const _d3 = dirty()
    failed = first(failed, check(branch(true, full).len, 0, 4))
    const _d4 = dirty()
    failed = first(failed, check(returned().len, 0, 5))
    const _d5 = dirty()
    failed = first(failed, check(arm(0, full).len, 0, 6))
    const _d6 = dirty()
    failed = first(failed, check(refilled(full).len, 2, 7))

    const _d7 = dirty()
    failed = first(failed, check(payload_len(Carrier.Full([1i64, 2])), 2, 8))

    const _d8 = dirty()
    const some: i64[]? = Some([1i64, 2, 3])
    failed = first(failed, check(some.unwrap().len, 3, 9))

    const _d9 = dirty()
    const pair: (i64[], i32) = ([1i64, 2], 3)
    failed = first(failed, check(pair.0.len, 2, 10))

    failed = first(failed, check(TABLE.len, 4, 11))

    const _d10 = dirty()
    const absent: i64[]? = null
    const fallback: i64[] = absent ?? [1i64, 2]
    failed = first(failed, check(fallback.len, 2, 12))

    const _d11 = dirty()
    failed = first(failed, check(defaulted(), 3, 13))

    const _d12 = dirty()
    const rows: [i64[]; 2] = [[1i64, 2], [3i64]]
    failed = first(failed, check(rows[1].len, 1, 14))

    failed = first(failed, check(produced_len({ => [] }), 0, 15))

    // An array decays where a slice is wanted, by value, by reference and at a binding.
    let typed: [i64; 3] = [7i64, 8, 9]
    const _d13 = dirty()
    failed = first(failed, check(count(typed), 3, 16))
    const _d14 = dirty()
    failed = first(failed, check(count(&typed), 3, 17))
    const _d15 = dirty()
    const view: i64[] = typed
    failed = first(failed, check(view.len, 3, 18))

    // A bare literal read in place is a slice of its storage.
    failed = first(failed, check([4i64, 5, 6][1] as usize, 5, 19))
    failed = first(failed, check([4i64, 5, 6].len, 3, 20))
    let total: i64 = 0
    for x in [4i64, 5, 6] {
        total = total + x
    }
    failed = first(failed, check(total as usize, 15, 21))
    return failed
}
