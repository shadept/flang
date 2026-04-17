//! TEST: stat_basic
//! EXIT: 0
//! STDOUT: ok

// stat() reports kind + size. exists/is_dir/is_file are thin wrappers.
// "/" is a known directory on POSIX; the tests that need it skip on Windows.

import std.io.fs

fn kind_is_dir(k: FileKind) bool {
    k match {
        Dir => true,
        _ => false,
    }
}

pub fn main() i32 {
    const info_r = stat("/")
    if info_r.is_err() { println("stat-/ failed"); return 1 }
    const info = info_r.unwrap()
    if !kind_is_dir(info.kind) { println("expected Dir"); return 2 }

    if !exists("/") { println("exists-/ failed"); return 3 }
    if !is_dir("/") { println("is_dir-/ failed"); return 4 }
    if is_file("/") { println("is_file-/ should be false"); return 5 }

    if exists("/this/does/not/exist/flang_stat_test") {
        println("exists-bogus should be false")
        return 6
    }
    if is_dir("/this/does/not/exist/flang_stat_test") {
        println("is_dir-bogus should be false")
        return 7
    }
    if is_file("/this/does/not/exist/flang_stat_test") {
        println("is_file-bogus should be false")
        return 8
    }

    println("ok")
    return 0
}
