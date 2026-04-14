//! TEST: address_of_field
//! EXIT: 42

// Taking the address of a struct field should produce a pointer
// into the struct (GEP), not a pointer to a temporary copy.

type Pair = struct { x: i32, y: i32 }

fn set_via_ptr(ptr: &i32, val: i32) {
    ptr.* = val
}

pub fn main() i32 {
    let p = Pair { x = 0, y = 0 }
    set_via_ptr(&p.x, 42)
    return p.x
}
