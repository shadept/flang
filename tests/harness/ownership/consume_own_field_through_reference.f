//! TEST: consume_own_field_through_reference
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

// An `owned` field of a type this module declares, reached through a reference, handed straight to
// a `move` parameter: the same right as `let h = move b.h`, spelled at the call.
fn empty_into(b: &Box) i32 {
    return close(b.h)
}

pub fn main() i32 {
    let b = Box { h = Handle { fd = 7 } }
    return empty_into(&b)
}
