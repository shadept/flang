//! TEST: stdlib_result_payloads_own
//! EXIT: 15

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

fn good(n: i32) Result(FileHandle, FileHandle) {
    return Ok(open(n))
}

fn bad(n: i32) Result(FileHandle, FileHandle) {
    return Err(open(n))
}

// Both payloads leave a result through `map`, `map_err` and `and_then`, whichever arm holds them.
pub fn main() i32 {
    const a = good(1).map_err(fn(e: move FileHandle) i32 { return close(e) }).unwrap().close()
    const b = bad(2).map(fn(h: move FileHandle) i32 { return close(h) }).unwrap_err().close()
    const c = bad(3).and_then(fn(h: move FileHandle) Result(i32, FileHandle) { return Ok(close(h)) })
        .unwrap_err().close()
    const d = good(4).map(fn(h: move FileHandle) i32 { return close(h) }).unwrap()
    const e = bad(5).map_err(fn(e: move FileHandle) i32 { return close(e) }).unwrap_err()
    return a + b + c + d + e
}
