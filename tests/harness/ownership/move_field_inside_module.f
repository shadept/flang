//! TEST: move_field_inside_module
//! EXIT: 3

type Inner = struct {
    owned fd: i32
}

fn deinit(self: Inner) {}

type Session = struct {
    conn: Inner
    id: i32
}

// The field's type is non-copyable, and the move is in the declaring module.
pub fn main() i32 {
    let s = Session { conn = .{ fd = 3 }, id = 1 }
    let taken = move s.conn
    return taken.fd
}
