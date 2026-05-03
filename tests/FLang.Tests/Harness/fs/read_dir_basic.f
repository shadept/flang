//! TEST: read_dir_basic
//! EXIT: 0
//! STDOUT: ok

// Opens a directory that is guaranteed to exist and contain entries,
// iterates it, and verifies: iteration completes without error and
// "." / ".." are filtered out.

import std.io.fs
import std.option
import std.result

pub fn main() i32 {
    let it = read_dir("/").unwrap()
    defer it.deinit()

    let count: i32 = 0
    for entry in it {
        // Filter check: neither "." nor ".." must appear.
        if entry.name == "." or entry.name == ".." {
            println("leaked_dotfile")
            return 1
        }
        count = count + 1
    }

    const e = it.err()
    if e.is_some() {
        println("iteration_error")
        return 2
    }

    if count == 0 {
        println("empty_root")
        return 3
    }

    println("ok")
    return 0
}
