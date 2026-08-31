//! TEST: owned_is_contextual
//! EXIT: 7

// `owned` is a modifier when an identifier follows and a field name when a colon does. Both
// readings appear here; the modifier changes no behaviour until RFC-028 enforcement lands.

type Handle = struct {
    owned fd: i32
}

// `owned` as the field's own name, in a struct that also declares a modifier.
type Mixed = struct {
    owned: i32
    owned tag: i32
}

pub fn main() i32 {
    let h = Handle { fd = 3i32 }
    let m = Mixed { owned = 1i32, tag = 3i32 }
    return h.fd + m.owned + m.tag
}
