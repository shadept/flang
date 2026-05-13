//! TEST: bitset_basic
//! EXIT: 0

import std.bitset
import std.option

pub fn main() i32 {
    let bs = bitset(0)
    defer bs.deinit()

    if !bs.is_empty() { return 1 }
    if bs.contains(0) { return 2 }
    if bs.contains(1000) { return 3 }       // way past capacity — must not crash

    bs.add(3)
    bs.add(64)                              // forces a second word
    bs.add(200)                             // forces growth to 4 words
    if bs.len() != 3 { return 4 }
    if !bs.contains(3) { return 5 }
    if !bs.contains(64) { return 6 }
    if !bs.contains(200) { return 7 }
    if bs.contains(5) { return 8 }

    // remove returns prior state.
    if !bs.remove(64) { return 9 }
    if bs.remove(64) { return 10 }
    if bs.contains(64) { return 11 }
    if bs.len() != 2 { return 12 }

    // iter — bits yielded in ascending order.
    let it = bs.iter()
    let a = it.next()
    let b = it.next()
    let c = it.next()
    if a.unwrap_or(0usize) != 3 { return 13 }
    if b.unwrap_or(0usize) != 200 { return 14 }
    if c.is_some() { return 15 }

    // union / intersect / difference
    let other = bitset(0)
    defer other.deinit()
    other.add(3)
    other.add(7)

    let u = bitset(0)
    defer u.deinit()
    u.add(3)
    u.add(200)
    u.union(other)
    if !u.contains(3) { return 16 }
    if !u.contains(7) { return 17 }
    if !u.contains(200) { return 18 }
    if u.len()!= 3 { return 19 }

    let inter = bitset(0)
    defer inter.deinit()
    inter.add(3)
    inter.add(200)
    inter.intersect(other)
    if !inter.contains(3) { return 20 }
    if inter.contains(200) { return 21 }
    if inter.len()!= 1 { return 22 }

    let diff = bitset(0)
    defer diff.deinit()
    diff.add(3)
    diff.add(7)
    diff.add(200)
    diff.difference(other)
    if diff.contains(3) { return 23 }
    if diff.contains(7) { return 24 }
    if !diff.contains(200) { return 25 }

    bs.clear()
    if !bs.is_empty() { return 26 }

    return 0
}
