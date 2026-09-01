//! TEST: defer_move_on_break_path
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

fn deinit(self: FileHandle) {}

// `break` unwinds the block's defers, so the move happens on that path too.
pub fn main() i32 {
    let h = open(3)
    loop {
        defer deinit(move h)
        if h.fd > 0 {
            break
        }
    }
    return close(move h)           // error E2123
}
