//! TEST: take_through_plain_pointer_refused
//! COMPILE-ERROR: E2125
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) i32 {
    return self.fd
}

// `slots` is not `owned`: the pointer names storage the type does not release, so nothing may be
// taken out of it through a reference, in either spelling.
type View = struct {
    slots: &Handle
    len: usize
}

fn take_at(self: &View, index: usize) i32 {
    return close((self.slots + index).*) // error E2125
}

pub fn main() i32 {
    let one = Handle { fd = 7 }
    let v = View { slots = &one, len = 1 }
    return take_at(&v, 0)
}
