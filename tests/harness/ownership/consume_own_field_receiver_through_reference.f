//! TEST: consume_own_field_receiver_through_reference
//! EXIT: 7

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) i32 {
    return self.fd
}

type Box = struct {
    owned h: Handle
}

// The receiver form of the same move: `b.h.close()` consumes this module's own `owned` field.
fn empty_into(b: &Box) i32 {
    return b.h.close()
}

pub fn main() i32 {
    let b = Box { h = Handle { fd = 7 } }
    return empty_into(&b)
}
