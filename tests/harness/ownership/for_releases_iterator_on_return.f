//! TEST: for_releases_iterator_on_return
//! EXIT: 2

import std.collections.list

fn first(xs: &List(i32)) i32 {
    for x in xs.drain() {
        return x
    }
    return 0
}

// A `return` from inside the loop releases the drain too: the two untaken elements go back.
pub fn main() i32 {
    let xs: List(i32) = list(4)
    xs.push(7)
    xs.push(8)
    xs.push(9)
    const _f = first(&xs)
    const n = xs.len as i32
    xs.deinit()
    return n
}
