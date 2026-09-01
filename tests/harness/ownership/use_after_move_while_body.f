//! TEST: use_after_move_while_body
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

pub fn main() i32 {
    let h = open(3)
    let i = 0
    while i < 2 {
        close(move h)                  // error E2123 on the second iteration
        i = i + 1
    }
    return 0
}
