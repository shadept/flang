//! TEST: error_e2157_foreign_struct_fn_field
//! COMPILE-ERROR: E2157

// A C layout holds a callback as one code pointer, `#foreign fn`, not a `{ code, env }` pair
// (RFC-037).

type Callbacks = #foreign struct {
    on_key: fn(i32)
}

pub fn main() i32 {
    return 0
}
