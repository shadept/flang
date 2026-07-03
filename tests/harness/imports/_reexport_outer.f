//! TEST: import_helper_reexport_outer
//! SKIP: helper module for pub_import_reexport — not run directly

pub import _reexport_inner

pub fn outer_value() i32 {
    return inner_value() + 1
}
