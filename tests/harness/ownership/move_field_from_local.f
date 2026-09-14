//! TEST: move_field_from_local
//! EXIT: 3

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

pub fn main() i32 {
    let s = Session { conn = open(3), id = 1 }
    return s.conn.close()
}
