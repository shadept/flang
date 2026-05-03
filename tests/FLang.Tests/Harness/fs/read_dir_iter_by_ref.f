//! TEST: read_dir_iter_by_ref
//! EXIT: 0
//! STDOUT: done=true
//! STDOUT: err=no

// Pins that `for entry in it` over a `DirIter` mutates the original `it`
// (iter-by-ref), so post-loop queries like `it.done` and `it.err()` reflect
// what actually happened during iteration.

import std.io.fs
import std.option
import std.result

pub fn main() i32 {
    let it = read_dir("/").unwrap()
    defer it.deinit()

    let count: usize = 0
    for entry in it {
        count = count + 1
    }

    // After iterating to completion, `done` must be true and `err` must be empty.
    if it.done { println("done=true") } else { println("FAIL: done=false") }

    const e = it.err()
    if e.is_some() { println("FAIL: err=yes") } else { println("err=no") }

    return 0
}
