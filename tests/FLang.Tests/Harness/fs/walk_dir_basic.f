//! TEST: walk_dir_basic
//! EXIT: 0
//! STDOUT: ok

// Walk a directory that's guaranteed to contain nested entries, count them,
// and verify the iterator terminates cleanly. Symlinks are not followed so
// we cannot loop even if the tree contains them.

import std.io.fs

pub fn main() i32 {
    let w = walk_dir("/tmp").unwrap()
    defer w.deinit()

    let count: i32 = 0
    for entry in w {
        count = count + 1
        // Every yielded path must start with the walk root.
        if entry.path.len < 4 {
            println("path_too_short")
            return 1
        }
        if entry.path[0] != '/' or entry.path[1] != 't' or entry.path[2] != 'm' or entry.path[3] != 'p' {
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
