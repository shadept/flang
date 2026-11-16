//! TEST: transitive_type_generic_body
//! EXIT: 42

// SH-102: a generic body from `_hidden_b` names `HiddenBox` from its own import, and still resolves
// when monomorphized for a call here, where `HiddenBox` is not visible.
import _hidden_b

pub fn main() i32 {
    return boxed_value(true)
}
