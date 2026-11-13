//! TEST: labeled_continue_carries_move
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

// `continue outer` carries the state it leaves with to the outer loop's next iteration.
pub fn main() i32 {
    let h = open(3)
    let n: i32 = 0
    outer: while n < 2 {
        n = n + h.fd // error E2123
        loop {
            h.close()
            continue outer
        }
    }
    return n
}
