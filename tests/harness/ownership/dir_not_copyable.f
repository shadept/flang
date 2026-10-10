//! TEST: dir_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.io.dir
import std.result

// A directory handle is closed once: a second binding would close it twice.
pub fn main() i32 {
    let d = open_dir(".").unwrap()
    let e = d // error E2124
    e.deinit()
    return 0
}
