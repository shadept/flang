//! TEST: char_literal_overload_order
//! EXIT: 0

// Regression for: char literals (codepoint 0-255) used to bind to an
// unconstrained TypeVar, so `foo("x", 'a')` scored ties against both
// `foo(String, char)` and `foo(String, String)` overloads. Declaration
// order then decided the winner.
//
// The constrained-TypeVar fix narrows char literals to `{u8, char}` so
// the String overload is filtered out entirely — the char overload
// always wins, regardless of declaration order.

// Declare the String overload FIRST. Before the fix this would win and
// `kind('x', 'a')` would call the String overload (wrong).
fn kind(s: String, n: String) i32 { return 1 }
fn kind(s: String, c: char) i32 { return 2 }
fn kind(s: String, b: u8) i32 { return 3 }

pub fn main() i32 {
    // 'a' is a char literal — must pick the char overload (2).
    if kind("x", 'a') != 2 { return 11 }

    // Explicit u8 context picks the u8 overload (3).
    let b: u8 = 'a'
    if kind("x", b) != 3 { return 12 }

    // Explicit String context picks the String overload (1).
    if kind("x", "a") != 1 { return 13 }

    return 0
}
