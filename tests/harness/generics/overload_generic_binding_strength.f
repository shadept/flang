//! TEST: overload_generic_binding_strength
//! EXIT: 0

// Between two overloads whose parameters are both type variables, the one
// binding its second parameter to the first (`b: T`) wins over the one
// leaving it free (`b: $F`). Each returns a distinct value, so a wrong pick
// shows up as a wrong answer.

fn helper() i32 { return 0i32 }

fn pick(a: $T, b: T) i32 { return 1i32 }
fn pick(a: $T, b: $F) i32 { return 2i32 }

// A callable returning its own type satisfies `b: T` and `b: $F` at once, so
// both overloads instantiate and the pick is not forced by typing alone.
pub type Rec = struct { tag: i32 }
pub fn op_call(self: &Rec) Rec { return Rec { tag = self.tag + 1i32 } }

pub fn main() i32 {
    // Both match: the tied parameter wins.
    if pick(1i32, 2i32) != 1i32 { return 1 }
    if pick(true, false) != 1i32 { return 2 }

    // Only the free parameter matches - `b` cannot be a `T` here.
    if pick(1i32, true) != 2i32 { return 3 }

    // A plain function value is a `T` like any other.
    if pick(helper, helper) != 1i32 { return 4 }

    // The case where both genuinely typecheck rather than one failing.
    let r = Rec { tag = 7i32 }
    if pick(r, r) != 1i32 { return 5 }

    return 0
}
