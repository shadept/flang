//! TEST: move_in_match_result
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
    let g = h.fd match {
        0 => open(4),
        else => move h,
    }
    return h.fd                        // error E2123
}
