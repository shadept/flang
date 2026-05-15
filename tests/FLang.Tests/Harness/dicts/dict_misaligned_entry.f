//! TEST: dict_misaligned_entry
//! EXIT: 0

// Regression for the "Dict Entry Stride Ignores Alignment Padding"
// bug (docs/known-issues.md). When `16 + size_of(K) + size_of(V)`
// isn't a multiple of 8, the prior `entry_byte_size` formula was
// off by the trailing struct padding and pointer arithmetic in
// probe/iter loops walked off-stride, corrupting the heap.
//
// Each case below hits a layout the old formula got wrong; with the
// fix in place all of them should set, look up, iterate, and deinit
// cleanly.

import std.dict
import std.option
import std.string

pub fn main() i32 {
    // (1) K = OwnedString (24), V = u8 (1) -> raw 41, padded 48
    {
        let d: Dict(OwnedString, u8) = dict()
        defer d.deinit()
        d.set(from_view("alpha"), 1u8)
        d.set(from_view("beta"), 2u8)
        d.set(from_view("gamma"), 3u8)
        d.set(from_view("delta"), 4u8)
        d.set(from_view("epsilon"), 5u8)
        d.set(from_view("zeta"), 6u8)
        d.set(from_view("eta"), 7u8)
        d.set(from_view("theta"), 8u8)
        if d.len() != 8 { return 1 }
        const v = d.get("epsilon")
        if v.is_none() { return 2 }
        if v.unwrap() != 5u8 { return 3 }
    }

    // (2) K = usize (8), V = u8 (1) -> raw 25, padded 32
    {
        let d: Dict(usize, u8) = dict()
        defer d.deinit()
        for i in 0..16usize {
            d.set(i, (i + 1) as u8)
        }
        if d.len() != 16 { return 4 }
        const v = d.get(7usize)
        if v.is_none() { return 5 }
        if v.unwrap() != 8u8 { return 6 }
    }

    // (3) K = u32 (4), V = u32 (4) -> raw 24, multiple of 8 already;
    //     sanity check that the fix didn't regress aligned layouts.
    {
        let d: Dict(u32, u32) = dict()
        defer d.deinit()
        d.set(1u32, 100u32)
        d.set(2u32, 200u32)
        if d.len() != 2 { return 7 }
        if d.get(2u32).unwrap() != 200u32 { return 8 }
    }

    // (4) K = u32 (4), V = u64 (8) -> raw 28, padded 32.
    //     Same shape that the FIR shim-inliner needed for u32→Operand.
    {
        let d: Dict(u32, u64) = dict()
        defer d.deinit()
        for i in 0..20u32 {
            d.set(i, (i as u64) * 1000u64 + 1u64)
        }
        if d.len() != 20 { return 9 }
        if d.get(13u32).unwrap() != 13001u64 { return 10 }
    }

    // (5) K = u32 (4), V = OwnedString (24) -> raw 44, padded 48.
    //     Exercises a value with internal pointer fields (8-byte align)
    //     so the key-to-value gap matters.
    {
        let d: Dict(u32, OwnedString) = dict()
        defer d.deinit()
        d.set(1u32, from_view("one"))
        d.set(2u32, from_view("two"))
        d.set(3u32, from_view("three"))
        d.set(4u32, from_view("four"))
        d.set(5u32, from_view("five"))
        d.set(6u32, from_view("six"))
        d.set(7u32, from_view("seven"))
        d.set(8u32, from_view("eight"))
        if d.len() != 8 { return 11 }
        const v = d.get(5u32)
        if v.is_none() { return 12 }
        if v.unwrap().as_view() != "five" { return 13 }
    }

    return 0
}
