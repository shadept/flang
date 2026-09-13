//! TEST: receiver_field_inside_module
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

type Session = struct {
    h: FileHandle
}

// A field receiver inside the declaring module: a partial move, unchecked here like `move s.h`.
fn shut(s: &Session) i32 {
    return s.h.close()
}

pub fn main() i32 {
    let s = Session { h = open(3) }
    return shut(&s)
}
