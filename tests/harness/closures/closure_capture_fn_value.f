//! TEST: closure_capture_fn_value
//! EXIT: 11

// A closure capturing a bare fn value must project the call through its
// env (`self.g`) instead of emitting a direct call to an undeclared `g`.
// Also covers the callee-only capture: `g` appears ONLY in call position,
// which bypasses InferIdentifier's capture recording.

fn apply(f: $F, x: i32) i32 { return f(x) }

pub fn main() i32 {
    let g = fn(x: i32) i32 { x * 2 }
    let h = fn(x: i32) i32 { g(x) + 1 }
    return apply(h, 5)
}
