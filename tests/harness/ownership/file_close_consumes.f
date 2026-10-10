//! TEST: file_close_consumes
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.io.file
import std.result

// `close_file` takes the file: a write after it would reach a descriptor the OS may have reused.
pub fn main() i32 {
    let f = open_file("flang_close_consumes.tmp", FileMode.Write).unwrap()
    const _c = close_file(f)
    const _w = write(&f, "late") // error E2123
    return 0
}
