//! TEST: error_e2035_self_field_only
//! COMPILE-ERROR: E2035 field `next` reaches back to it

// The offending field is the only one that loses its type: `tag` still checks, so a second
// diagnostic about it would mean the poison had cascaded.
type SelfContaining = struct {
    next: SelfContaining
    tag: i32
}

pub fn main() i32 {
    return 0
}
