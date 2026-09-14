//! TEST: move_receiver_kills_binding
//! COMPILE-ERROR: E2123 was moved
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

// The receiver follows the picked overload's first parameter: `close` takes ownership.
pub fn main() i32 {
    let h = open(3)
    let n = h.close()
    return n + h.fd                // error E2123
}
