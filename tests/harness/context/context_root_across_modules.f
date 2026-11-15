//! TEST: context_root_across_modules
//! EXIT: 0

// The root context holds every module's defaults at their own offsets, whatever order the modules
// are lowered in: `std.task` declares `job` and comes before `std.allocator`'s fields here.

import std.allocator
import std.option
import std.task

pub fn main() i32 {
    const m: Memory = alloc(context.allocator, 16, 8) ?? return 1
    leak(m)
    if context.job.is_cancelled() {
        return 2
    }
    return 0
}
