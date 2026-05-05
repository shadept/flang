//! TEST: error_op_call_no_match
//! COMPILE-ERROR: E2004

// `c` has no `op_call` defined and isn't a function pointer — call must error.
// Today this surfaces as "Unresolved function" (E2004); the diagnostic could be
// upgraded later, but the failure mode is what matters.

type Bag = struct { n: i32 }

pub fn main() i32 {
    let c = Bag { n = 0 }
    let v = c(1)
    return v
}
