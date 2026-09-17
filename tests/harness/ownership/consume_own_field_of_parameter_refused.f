//! TEST: consume_own_field_of_parameter_refused
//! COMPILE-ERROR: E2123
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) i32 {
    return self.fd
}

type Box = struct {
    h: Handle
}

// An owned binding still tracks the field: consuming it twice is a use after move.
pub fn main() i32 {
    let b = Box { h = Handle { fd = 7 } }
    const a = close(b.h)
    return close(b.h) + a // error E2123
}
