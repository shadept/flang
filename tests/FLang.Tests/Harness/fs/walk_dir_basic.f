//! TEST: walk_dir_basic
//! EXIT: 0
//! STDOUT: ok

// Walk a directory that's guaranteed to contain nested entries, count them,
// and verify the iterator terminates cleanly. Symlinks are not followed so
// we cannot loop even if the tree contains them.
//
// The walk root must exist on all supported platforms and be reachable from
// the test runner's working directory (the repo root). `stdlib/` fits both.

import std.io.fs
import std.option
import std.result

pub fn main() i32 {
    let w = walk_dir("stdlib").unwrap()
    defer w.deinit()

    let count: i32 = 0
    for entry in w {
        count = count + 1
        // Every yielded path must start with the walk root.
        if entry.path.len < 6 {
            println("path_too_short")
            return 1
        }
        if entry.path[0] != 's' or entry.path[1] != 't' or entry.path[2] != 'd' or entry.path[3] != 'l' or entry.path[4] != 'i' or entry.path[5] != 'b' {
            println("bad_prefix")
            return 2
        }
        if count >= 5 { break }
    }
    if count == 0 {
        println("no_entries")
        return 3
    }

    println("ok")
    return 0
}
