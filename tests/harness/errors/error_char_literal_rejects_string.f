//! TEST: char_literal_rejects_string
//! COMPILE-ERROR: E2011

// A constrained char-literal TypeVar may only resolve to `u8` or `char`.
// Assigning it where a String is expected must error rather than silently
// binding the TypeVar to `String`.

fn takes_string(s: String) i32 { return 0 }

pub fn main() i32 {
    return takes_string('a')
}
