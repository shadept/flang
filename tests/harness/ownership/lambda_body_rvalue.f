//! TEST: lambda_body_rvalue
//! COMPILE-ERROR: E2132
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
    let f = fn() i32 {
        open(3)                     // error E2132
        return 0
    }
    return f()
}
