//! TEST: move_plain_field_through_reference_refused
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

// The explicit spelling of move_field_from_ref_param: `conn` is a plain field, so declaring
// `Session` grants no right to take it through a reference. Only an `owned` field does.
fn steal(s: &Session) i32 {
    let c = move s.conn // error E2131
    return c.close()
}

pub fn main() i32 {
    let s = Session { conn = open(3), id = 1 }
    return steal(&s)
}
