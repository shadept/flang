//! TEST: field_move_explicit
//! COMPILE-ERROR: E2123 `s` is incomplete
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

// `let t = move s.db` marks the field like a `move` parameter does.
pub fn main() i32 {
    let s = server()
    let t = move s.db
    let u = move s                 // error E2123
    return close(t)
}
