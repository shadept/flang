//! TEST: slice_of_optionals_suffix
//! EXPECT: 2
//! EXPECT: 8

// Type suffixes apply left to right: `i32?[]` is a slice of `i32?`, `i32[]?` an optional slice.

import std.io.print
import std.option

fn present(xs: i32?[]) i32 {
    let n: i32 = 0
    for o in xs {
        if o.is_some() {
            n = n + 1
        }
    }
    return n
}

fn total(s: i32[]?) i32 {
    let xs: i32[] = s ?? return -1
    let t: i32 = 0
    for x in xs {
        t = t + x
    }
    return t
}

pub fn main() i32 {
    let os: [i32?; 3] = [Some(1), null, Some(3)]
    println(present(os))
    let vs: [i32; 2] = [3, 5]
    let s: i32[] = vs
    println(total(Some(s)))
    return 0
}
