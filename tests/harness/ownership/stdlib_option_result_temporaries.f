//! TEST: stdlib_option_result_temporaries
//! EXIT: 12

import std.option
import std.result

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn maybe(n: i32) FileHandle? {
    return Some(open(n))
}

fn attempt(n: i32) Result(FileHandle, i32) {
    return Ok(open(n))
}

fn run() Result(i32, i32) {
    const h = attempt(4)?
    return Ok(close(h))
}

// A temporary option or result reaches an owner through `unwrap` and `?`.
pub fn main() i32 {
    const a = maybe(3).unwrap().close()
    const b = run().unwrap()
    const c = attempt(5).unwrap().close()
    return a + b + c
}
