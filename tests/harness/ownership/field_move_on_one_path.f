//! TEST: field_move_on_one_path
//! COMPILE-ERROR: E2123 `self` is incomplete
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

fn maybe_close(self: move Server, c: bool) Server {
    if c {
        let _n = self.log.close()
    }
    return self                    // error E2123 (one path)
}

pub fn main() i32 {
    let s = maybe_close(server(), true)
    return s.port
}
