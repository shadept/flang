//! TEST: generics_cannot_infer_from_context
//! COMPILE-ERROR: E2011

pub fn identity(x: $T) T {
    return x
}

pub fn main() i32 {
    // No expected type; inference from args only -> no applicable overload
    let y = identity(0)
    return 0
}
