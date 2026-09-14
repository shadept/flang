//! TEST: coalesce_fallback_follows_result
//! COMPILE-ERROR: E2132
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn peek(h: FileHandle) i32 {
    return h.fd
}

// `a ?? b` is `a match { Some(v) => v, None => b }`: `b` goes where the result goes.
pub fn main() i32 {
    let o: FileHandle? = null
    let kept = o ?? open(1)
    return kept.close() + peek(o ?? open(2)) // error E2132
}
