//! TEST: field_move_address
//! COMPILE-ERROR: E2123 `s.log` was moved
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

fn peek(h: &FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let s = server()
    let _n = s.log.close()
    return peek(&s.log)            // error E2123
}
