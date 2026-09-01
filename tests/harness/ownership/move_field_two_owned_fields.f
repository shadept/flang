//! TEST: move_field_two_owned_fields
//! EXIT: 2

type Inner = struct {
    owned fd: i32
}

let closed: i32 = 0

fn deinit(self: Inner) {
    closed = closed + 1
}

type Session = struct {
    conn: Inner
    log: Inner
}

// Two fields whose type is non-copyable, disassembled by the type's own deinit.
// Nothing marks the base, so the second move is fine.
fn deinit(self: Session) {
    deinit(move self.conn)
    deinit(move self.log)
}

pub fn main() i32 {
    let s = Session { conn = .{ fd = 1 }, log = .{ fd = 2 } }
    deinit(move s)
    return closed
}
