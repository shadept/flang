//! TEST: import_helper_hidden_b
//! SKIP: helper module for transitive_type_* - not run directly

import _hidden_a

pub fn boxed_value(tag: $T) i32 where T: copyable {
    const b: HiddenBox = .{ x = 42 }
    return b.x
}
