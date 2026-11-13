//! TEST: labeled_break_carries_move
//! COMPILE-ERROR: E2123
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

// `break outer` carries the state it leaves with to the outer loop's exit.
pub fn main() i32 {
    let h = open(3)
    outer: loop {
        loop {
            h.close()
            break outer
        }
    }
    return h.fd // error E2123
}
