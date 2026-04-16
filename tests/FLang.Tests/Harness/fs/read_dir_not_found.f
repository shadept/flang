//! TEST: read_dir_not_found
//! EXIT: 0
//! STDOUT: not_found

import std.io.fs

pub fn main() i32 {
    const r = read_dir("/this/path/should/never/exist/flang_fs_test")
    r match {
        Ok(it) => {
            it.deinit()
            println("unexpected_ok")
            return 1
        },
        Err(e) => {
            e match {
                NotFound => { println("not_found"); return 0 },
                PermissionDenied => { println("denied"); return 2 },
                NotADirectory => { println("not_a_dir"); return 3 },
                NameTooLong => { println("too_long"); return 4 },
                NotSupported => { println("not_supported"); return 5 },
                InvalidArgument => { println("invalid"); return 6 },
                IOError => { println("io"); return 7 },
            }
        },
    }
}
