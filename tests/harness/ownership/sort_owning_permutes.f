//! TEST: sort_owning_permutes
//! EXIT: 0

import std.collections.list
import std.string
import std.string_builder

// Sorting owning elements past the insertion cutoff orders indices, then permutes the list in place
// by swaps: every string ends in exactly one slot, in order.
pub fn main() i32 {
    let xs: List(OwnedString) = list(64)
    for i in 0usize..64 {
        const k = (i * 37) % 64
        xs.push($"{k / 10}{k % 10}")
    }
    xs.sort()
    let bad: i32 = 0
    for i in 1..xs.len {
        if !(xs[i - 1].view < xs[i].view) {
            bad = bad + 1
        }
    }
    xs.deinit()
    return bad
}
