//! TEST: remove_file
//! EXIT: 0
//! STDOUT: created gone missing_is_not_found

import std.io.file
import std.io.fs
import std.result

// remove_file reports FileError: unlinking is something you do to a file, so
// the directory-shaped failures are not in its error type at all.
fn write_fixture(path: String) bool {
    const opened = open_file(path, FileMode.Write)
    if opened.is_err() { return false }
    let f = opened.unwrap()
    const w = write(&f, "doomed")
    const c = close_file(&f)
    return w.is_ok() and c.is_ok()
}

fn is_not_found(e: FileError) bool {
    return e match {
        NotFound => true,
        _ => false,
    }
}

pub fn main() i32 {
    const path = "flang_remove_file_test.tmp"

    if !write_fixture(path) { println("write_failed"); return 1 }
    if !exists(path) { println("missing_after_write"); return 2 }
    print("created ")

    if remove_file(path).is_err() { println("remove_failed"); return 3 }
    if exists(path) { println("still_there"); return 4 }
    print("gone ")

    // A second removal has nothing to unlink.
    const again = remove_file(path)
    if again.is_ok() { println("unexpected_ok"); return 5 }
    if !is_not_found(again.unwrap_err()) { println("wrong_error"); return 6 }

    println("missing_is_not_found")
    return 0
}
