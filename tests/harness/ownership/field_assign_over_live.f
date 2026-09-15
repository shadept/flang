//! TEST: field_assign_over_live
//! COMPILE-ERROR: E2126 `s.log` is live
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
type Server = struct {
    log: FileHandle
    db: FileHandle
    port: i32
}
fn server() Server {
    return .{ log = open(1), db = open(2), port = 80 }
}

// Assigning a live field of an owned binding leaks what it holds, as a live binding does.
pub fn main() i32 {
    let s = server()
    s.log = open(9)                // error E2126
    return s.port
}
