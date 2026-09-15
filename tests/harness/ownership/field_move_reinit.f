//! TEST: field_move_reinit
//! EXIT: 85

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

// Assigning the moved field makes the base whole again.
fn rotate(self: move Server) Server {
    let n = self.log.close()
    self.log = open(n + 4)
    return self
}

pub fn main() i32 {
    let s = rotate(server())
    return s.port + s.log.fd
}
