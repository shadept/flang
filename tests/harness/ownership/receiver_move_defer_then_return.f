//! TEST: receiver_move_defer_then_return
//! COMPILE-ERROR: E2123 was moved
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

fn deinit(self: FileHandle) {}

// The return expression moves `h` first, then the defer runs on the moved binding.
fn take() FileHandle {
    let h = open(3)
    defer h.deinit()
    return move h
}

pub fn main() i32 {
    let h = take()
    return h.close()
}
