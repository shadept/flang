//! TEST: context_private_field
//! COMPILE-ERROR: E2150
//! EXIT: 1

import _ctx_lib

pub fn main() i32 {
    return context.secret // error E2150: private to _ctx_lib
}
