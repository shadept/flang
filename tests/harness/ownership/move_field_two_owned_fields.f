//! TEST: move_field_two_owned_fields
//! EXIT: 2

type Inner = struct {
    owned fd: i32
}

let closed: i32 = 0

fn deinit(self: move Inner) {
    closed = closed + 1
}

type Session = struct {
    conn: Inner
    log: Inner
}

// Two fields whose type is non-copyable, disassembled by the type's own deinit. Each move marks only
// its own field, so the second is fine, and `self` is never used whole afterwards.
fn deinit(self: move Session) {
    self.conn.deinit()
    self.log.deinit()
}

pub fn main() i32 {
    let s = Session { conn = .{ fd = 1 }, log = .{ fd = 2 } }
    s.deinit()
    return closed
}
