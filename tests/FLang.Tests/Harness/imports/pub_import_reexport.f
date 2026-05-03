//! TEST: pub_import_reexport
//! EXIT: 17

// _reexport_outer pub-imports _reexport_inner, so a module that imports
// _reexport_outer should also see _reexport_inner's pub items.

import _reexport_outer

pub fn main() i32 {
    return inner_value()
}
