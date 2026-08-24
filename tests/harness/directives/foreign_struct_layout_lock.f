//! TEST: foreign_struct_layout_lock
//! STDOUT: PASS

// Spec 2.4 / 10: a plain struct's layout belongs to the compiler, which may
// reorder fields to minimise footprint; `#foreign` opts out and follows C --
// declaration order with C padding, never reordered.
//
// Regression: the checker dropped `#foreign` (and `#simd`) when registering
// a struct declaration, so every struct took the `Repr.Auto` path and a
// `#foreign struct` got packed by descending alignment -- silently giving it
// a layout no C declaration of the same members matches.
//
// Only the `#foreign` half is asserted exactly, because it is the half the
// spec pins. Whether a PLAIN struct is actually reordered is a compiler's
// choice: the self-hosted compiler packs this one to 16, the reference
// leaves it at 24 (docs/known-issues.md). The inequality holds either way
// and still catches the bug, since the regression made `Locked` the SMALLER
// of the two.

import core.io

// Declaration order with C padding: 1 + 7 pad + 8 + 1 + 7 pad = 24.
type Plain  = struct { a: u8, big: u64, b: u8 }
type Locked = #foreign struct { a: u8, big: u64, b: u8 }

pub fn main() i32 {
    if size_of(Locked) != 24 as usize {
        println("FAIL: #foreign must keep C's declaration order and padding")
        return 1
    }
    if size_of(Plain) > size_of(Locked) {
        println("FAIL: a plain struct must never be larger than the C layout")
        return 1
    }
    println("PASS")
    return 0
}
