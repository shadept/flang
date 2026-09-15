//! TEST: stdlib_option_try_owner
//! EXIT: 9

import std.option

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

fn none() FileHandle? {
    return null
}

fn run() i32? {
    const a = maybe(4)?
    const b = maybe(5)
    const c = b ?? open(0)
    return Some(close(a) + close(c))
}

fn fallback() i32 {
    return none().unwrap_or(open(0)).close()
        + maybe(1).map(fn(h: move FileHandle) i32 { return close(h) }).unwrap_or(0)
        + maybe(2).filter(fn(h: FileHandle) bool { return h.fd > 5 }).map(fn(h: move FileHandle) i32 { return close(h) }).unwrap_or(0)
}

// A payload leaves an option through `?`, `??`, `unwrap_or`, `map` and `filter`.
pub fn main() i32 {
    return run().unwrap() + fallback() - 1
}
