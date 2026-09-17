//! TEST: consume_through_reference_refused
//! COMPILE-ERROR: E2125
//! EXIT: 1

type Handle = struct {
    owned fd: i32
}

fn close(self: move Handle) i32 {
    return self.fd
}

// A lent reference carries no storage of this module's, so handing its pointee to a consumer is
// refused exactly as `move h.*` is.
fn steal(h: &Handle) i32 {
    return close(h.*) // error E2125
}

pub fn main() i32 {
    let h = Handle { fd = 3 }
    return steal(&h)
}
