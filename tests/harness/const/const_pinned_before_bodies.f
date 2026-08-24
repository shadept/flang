//! TEST: const_pinned_before_bodies
//! STDOUT: PASS

// An unannotated module-level `const` only gets a fresh type variable in
// the signature pass. If a function body is checked before the const's
// initializer, that open var unifies with EVERY candidate in an overload
// probe at equal cost and declaration order picks the winner - which is
// how `stdin.reader()` resolved to `reader(&BufferedReader)`. Constants
// are pinned in their own phase before any body now.

type A = struct { tag: i32 }
type B = struct { tag: i32 }

fn kind(self: &A) i32 { return 1 }
fn kind(self: &B) i32 { return 2 }

// Declared AFTER the body that uses it, and after both overloads.
pub fn main() i32 {
    if GA.kind() != 1 { println("FAIL: method form"); return 1 }
    if kind(&GA) != 1 { println("FAIL: call form"); return 1 }
    println("PASS")
    return 0
}

const GA = A { tag = 9 }
