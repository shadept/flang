//! TEST: lambda_body_liveness
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

// A lambda body is checked like any function body.
pub fn main() i32 {
    let f = fn(h: move FileHandle) i32 {
        let n = h.close()
        return n + h.fd             // error E2123
    }
    return f(open(3))
}
