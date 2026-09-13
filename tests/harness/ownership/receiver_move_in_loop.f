//! TEST: receiver_move_in_loop
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

pub fn main() i32 {
    let h = open(3)
    let n = 0
    for _i in 0..2 {
        n = n + h.close()          // error E2123 on the second iteration
    }
    return n
}
