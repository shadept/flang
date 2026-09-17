//! TEST: move_out_of_own_storage
//! EXIT: 7

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) {
}

// A tiny container: `slots` is its own `owned` storage, so this module may take an element back out
// of it - the same right that lets it store one. The value behind a reference it was merely handed
// stays with its owner (see move_through_reference_refused).
type Slots = struct {
    owned slots: &Handle
    len: usize
}

// The chain stays written out: a local reference binding loses the provenance the rule reads.
fn take_at(self: &Slots, index: usize) Handle {
    return move (self.slots + index).*
}

pub fn main() i32 {
    let one = Handle { fd = 7 }
    let store = Slots { slots = &one, len = 1 }
    const taken = take_at(&store, 0)
    const fd = taken.fd
    taken.close()
    return fd
}
