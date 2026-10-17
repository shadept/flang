//! TEST: default_arg_helper_size
//! SKIP: helper module for default_arg_declaring_scope - not run directly

import _default_arg_kind

pub fn size(kind: Kind = Kind.Large) i32 {
    return kind match {
        Small => 1i32
        Large => 2i32
    }
}
