//! TEST: enum_padding_hash
//! EXIT: 0

// Enum construction zero-fills its whole allocation, so the padding
// between the i32 tag and an 8-aligned payload, and the unused space of
// smaller variants, must read as zero. The byte-wise generic hash then
// gives equal values equal hashes no matter what the stack held before
// construction: dirty() and the make_* helpers run at the same stack
// depth so their frames overlap.

import std.option

type E = enum {
    A(u64)
    B
}

fn dirty(fill: u8) u64 {
    let buf: [u8; 4096]
    for i in 0..4096 {
        buf[i] = fill
    }
    let s: u64 = 0
    for i in 0..4096 {
        s = s + buf[i] as u64
    }
    return s
}

fn opt_hash() usize {
    let o: u64? = Option.Some(2u64)
    return hash(o)
}

fn none_hash() usize {
    let o: u64? = null
    return hash(o)
}

fn enum_hash() usize {
    let e: E = E.A(2u64)
    return hash(e)
}

fn naked_hash() usize {
    let e: E = E.B
    return hash(e)
}

pub fn main() i32 {
    dirty(0)
    let h1: usize = opt_hash()
    dirty(255)
    let h2: usize = opt_hash()
    if h1 != h2 {
        return 1
    }

    dirty(0)
    let n1: usize = none_hash()
    dirty(255)
    let n2: usize = none_hash()
    if n1 != n2 {
        return 2
    }

    dirty(0)
    let e1: usize = enum_hash()
    dirty(255)
    let e2: usize = enum_hash()
    if e1 != e2 {
        return 3
    }

    dirty(0)
    let b1: usize = naked_hash()
    dirty(255)
    let b2: usize = naked_hash()
    if b1 != b2 {
        return 4
    }

    return 0
}
