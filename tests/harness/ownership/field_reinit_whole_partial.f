//! TEST: field_reinit_whole_partial
//! COMPILE-ERROR: E2126 `s` is live
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

// Only `log` was moved out: assigning the whole base would leak `db`.
pub fn main() i32 {
    let s = server()
    let _a = s.log.close()
    s = server()                   // error E2126
    return s.port
}
