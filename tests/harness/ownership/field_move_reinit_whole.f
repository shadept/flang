//! TEST: field_move_reinit_whole
//! EXIT: 80

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

// Assigning the whole base reinitializes every field.
pub fn main() i32 {
    let s = server()
    let _a = s.log.close()
    let _b = s.db.close()
    s = server()
    return s.port
}
