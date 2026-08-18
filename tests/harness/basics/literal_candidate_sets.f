//! TEST: literal_candidate_sets
//! EXIT: 0

// Unsuffixed numeric literals used to get a completely unconstrained type
// variable, so they would unify with whatever an overload happened to take -
// `String` included. `3.14` bound to `String` type-checked clean and only
// failed at the C compiler because `double*` and `String*` differ; between
// two same-width types it would have compiled and produced garbage.
//
// Both literal kinds now carry the primitive candidate set that
// `ValidatePostInference` was already checking after the fact. Enforcing it
// at unification time is what stops a wrong overload being *selected*,
// rather than complaining once the choice is already committed.
//
// The String overload is declared FIRST in each pair: ties fall through to
// declaration order, so if the constraint were absent it would win.

fn ikind(s: String) i32 { return 1 }
fn ikind(n: i64) i32 { return 2 }

fn fkind(s: String) i32 { return 1 }
fn fkind(f: f64) i32 { return 2 }

// The candidate set is deliberately wide - every one of these resolves by
// plain unification, so all of them have to stay legal.
fn widths() bool {
    let c: char = 65
    let n: u8 = 3
    let s: usize = 4
    let f: f32 = 2.5
    let d: f64 = 1
    return c == 65 and n == 3 and s == 4 and f == 2.5 and d == 1.0
}

// A constrained literal still has to reach the `T -> Option(T)` wrap. The
// constraint describes what the literal becomes, which is the payload - not
// the Option - so it must not veto the coercion.
fn opt_int() i64? { return 7 }
fn opt_float() f64? { return 3.5 }

pub fn main() i32 {
    if ikind(10) != 2 { return 11 }
    if fkind(3.14) != 2 { return 12 }
    if !widths() { return 13 }

    let oi = opt_int()
    let of = opt_float()
    let got_int = oi match { Some(v) => v, None => 0i64 }
    let got_float = of match { Some(v) => v, None => 0.0f64 }
    if got_int != 7 { return 14 }
    if got_float != 3.5 { return 15 }
    return 0
}
