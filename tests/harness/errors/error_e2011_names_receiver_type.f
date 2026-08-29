//! TEST: error_e2011_names_receiver_type
//! COMPILE-ERROR: E2011
//! STDERR: on `&Widget`

// A failed overload names the receiver's type. Which method missed matters far less than which type
// missed it: inside a generic container the call site is the container's own body, so the element
// type is the only thing identifying the instantiation at fault.

type Widget = struct {
    id: i32
}

type Gadget = struct {
    id: i32
}

fn drop_it(g: &Gadget) {}

fn take(w: &Widget) {
    w.drop_it()
}

pub fn main() i32 {
    let w = Widget { id = 1 }
    take(&w)
    return 0
}
