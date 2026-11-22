//! TEST: context_rebind_temporary_address
//! EXIT: 0

// A rebind to the address of a copyable call result keeps the temporary for the whole body: every
// allocation inside reaches the arena through it.

import std.allocator
import std.collections.list

fn fill(n: i32) i64 {
    let xs: List(i64) = list(0, context.temp_allocator)
    for i in 0..n {
        xs.push(i as i64)
    }
    let total: i64 = 0i64
    for x in xs {
        total = total + x
    }
    xs.deinit()
    return total
}

pub fn main() i32 {
    let arena: ArenaAllocator = arena_allocator(context.allocator)
    defer arena.deinit()
    const sum: i64 = context(temp_allocator = &arena.allocator()) { fill(1000) + fill(2000) }
    const served: bool = arena.page_count() > 0
    return if sum == 2498500i64 and served { 0 } else { 1 }
}
