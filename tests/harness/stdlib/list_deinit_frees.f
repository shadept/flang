//! TEST: list deinit frees elements and buffer through the allocator
//! EXIT: 0
//! STDOUT: deallocs=3

// Regression for overload resolution picking the universal no-op
// `deinit(&$T)` fallback over `deinit(&List($T))` (declaration order
// used to win the tie): container cleanup silently did nothing. With
// the specificity tie-break, deinit cascades - two element buffers
// plus the list's own storage - all through the decorator, which is
// what makes the cascade observable. A broken tie-break gives 1.
//
// The count is the assertion, not the byte totals: `from_view` grows its
// buffer with `realloc`, and a `List` buffer is handed out at `cap` and
// given back over the slice's extent, so `CountingAllocator`'s byte and
// alloc counters do not balance even when every block is returned.

import std.allocator
import std.list
import std.string
import core.io

fn main() i32 {
    let c = counting_allocator(global())
    let a = c.allocator()

    let xs: List(OwnedString) = list(2, Some(&a))
    xs.push(from_view("hello", Some(&a)))
    xs.push(from_view("world", Some(&a)))
    xs.deinit()
    print("deallocs=")
    let _b = println(c.deallocs)
    return 0
}
