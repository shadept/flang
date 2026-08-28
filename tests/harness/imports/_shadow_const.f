//! TEST: import_helper_shadow_const
//! SKIP: helper module for const_shadows_fn_value - not run directly

pub type Probe = struct {
    tag: i32
}

pub const probe = Probe { tag = 40 }

pub fn tag_plus(self: &Probe, n: i32) i32 {
    return self.tag + n
}
