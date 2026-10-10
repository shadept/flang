//! TEST: for_releases_iterator_on_break
//! EXIT: 2

import std.collections.list

// The loop owns the drain `iter` handed it and releases it on `break`: the untaken elements go back
// to the list.
pub fn main() i32 {
    let xs: List(i32) = list(4)
    xs.push(1)
    xs.push(2)
    xs.push(3)
    for x in xs.drain() {
        if x == 1 {
            break
        }
    }
    const n = xs.len as i32
    xs.deinit()
    return n
}
