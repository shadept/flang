//! TEST: import_helper_shadow_fn
//! SKIP: helper module for const_shadows_fn_value - not run directly

pub type Widget = struct {
    id: i32
}

// Same name as _shadow_const's `probe` const: a single-overload function that a
// value-position lookup could mistake for the identifier's meaning.
pub fn probe(self: &Widget) i32 {
    return self.id
}
