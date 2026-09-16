//! TEST: move_through_reference_refused
//! COMPILE-ERROR: E2125
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) {
}

// A lent reference carries no ownership, so taking the value behind one would let any module
// consume what it was only shown. Only the module that declares the storage may take out of it.
fn steal(h: &Handle) {
    let taken = move h.*
    taken.close()
}

pub fn main() i32 {
    let h = Handle { fd = 3 }
    steal(&h)
    return 0
}
