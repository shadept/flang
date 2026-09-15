//! TEST: field_move_then_use_base
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

// A base whose field was moved out is incomplete: handing it on would release `log` twice.
fn shutdown(self: move Server) Server {
    let _n = self.log.close()
    return self                    // error E2123
}

pub fn main() i32 {
    let s = shutdown(server())
    return s.port
}
