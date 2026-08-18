//! TEST: undetermined_literal_overload
//! COMPILE-ERROR: E2011

// `65` could be `char` or `usize` and both produce valid code, so this call
// is genuinely undetermined - FLang does not default literals, and there is
// nothing here to pick one. It used to resolve by declaration order, which
// made the *first-declared* overload silently decide the type. That is how
// `let l = list(4); l.push(65); println($"{l[0usize]}")` became a
// `List(char)` and printed `A`.
//
// Contrast tests/harness/basics/char_literal_overload_order.f: a char
// literal ties the same way but HAS a preferred type, so it settles on
// `char` rather than reporting.

fn kind(c: char) i32 { return 1 }
fn kind(u: usize) i32 { return 2 }

pub fn main() i32 {
    let x = 65
    return kind(x)
}
