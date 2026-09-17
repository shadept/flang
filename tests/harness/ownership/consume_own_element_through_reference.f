//! TEST: consume_own_element_through_reference
//! EXIT: 7

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) i32 {
    return self.fd
}

type Slots = struct {
    owned slots: &Handle
    len: usize
}

// An element of this module's own `owned` storage handed straight to a `move` parameter, as `let h
// = move (self.slots + index).*` may.
fn close_at(self: &Slots, index: usize) i32 {
    return close((self.slots + index).*)
}

pub fn main() i32 {
    let one = Handle { fd = 7 }
    let store = Slots { slots = &one, len = 1 }
    return close_at(&store, 0)
}
