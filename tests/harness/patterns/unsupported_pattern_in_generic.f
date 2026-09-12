//! TEST: unsupported_pattern_in_generic
//! COMPILE-ERROR: E2115 unsupported pattern form
//! EXIT: 1

// A generic template's body is never checked until something instantiates it, so a pattern the
// projector cannot read has to be reported at projection to be reported at all. Nothing calls
// `first`.
fn first(self: Option($T)) T? {
    return self match {
        Some(move v) => Some(move v)
        None => None
    }
}

pub fn main() i32 {
    return 0
}
