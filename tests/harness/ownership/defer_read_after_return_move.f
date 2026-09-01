//! TEST: defer_read_after_return_move
//! COMPILE-ERROR: E2123
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

fn log(n: i32) {}

// The return expression runs BEFORE the defer (spec 4.1), so the deferred read
// sees a moved binding.
pub fn main() i32 {
    let h = open(3)
    defer log(h.fd)
    return close(move h)
}
