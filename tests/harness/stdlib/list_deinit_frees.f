//! TEST: list deinit frees elements and buffer through the allocator
//! EXIT: 0
//! STDOUT: leaks=0
//! STDOUT: deallocs=3

// Regression for overload resolution picking the universal no-op
// `deinit(&$T)` fallback over `deinit(&List($T))` (declaration order
// used to win the tie): container cleanup silently did nothing. With
// the specificity tie-break, deinit cascades - two element buffers
// plus the list's own storage - all through the tracking allocator.

import std.allocator
import std.list
import std.string
import core.io

fn main() i32 {
    let xs: List(OwnedString) = list(2, Some(&test_allocator))
    xs.push(from_view("hello", Some(&test_allocator)))
    xs.push(from_view("world", Some(&test_allocator)))
    xs.deinit()
    print("leaks=")
    let _a = println(check_leaks(&test_allocator_state))
    print("deallocs=")
    let _b = println(test_allocator_state.dealloc_count)
    return 0
}
