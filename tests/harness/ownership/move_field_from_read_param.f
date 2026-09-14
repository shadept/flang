//! TEST: move_field_from_read_param
//! COMPILE-ERROR: E2131
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

type Session = struct {
    conn: FileHandle
    id: i32
}

fn steal(s: Session) i32 {
    return s.conn.close()          // error E2131: `s` is not owned here
}

pub fn main() i32 {
    let s = Session { conn = open(3), id = 1 }
    return steal(s)
}
