//! TEST: field_move_nested
//! COMPILE-ERROR: E2123 `p.a` is incomplete
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

type Pair = struct {
    a: Server
    b: Server
}

// A move deep in a path makes every enclosing place incomplete, and no sibling.
pub fn main() i32 {
    let p = Pair { a = server(), b = server() }
    let _n = p.a.log.close()
    let ok = p.a.db.fd + p.b.log.fd
    let whole = move p.a           // error E2123
    return ok
}
