//! TEST: read_dir_not_found
//! EXIT: 0
//! STDOUT: not_found

import std.io.dir

pub fn main() i32 {
    const r = open_dir("/this/path/should/never/exist/flang_fs_test")
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
                AlreadyExists => { println("exists"); return 5 },
                NotEmpty => { println("not_empty"); return 6 },
                InvalidArgument => { println("invalid"); return 7 },
                IOError => { println("io"); return 8 },
            }
        },
    }
}
