//! TEST: fn_type_move_call_kills
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

pub fn main() i32 {
    let f: fn(move FileHandle) i32 = close
    let h = open(3)
    let n = f(h)
    return n + h.fd                // error E2123
}
