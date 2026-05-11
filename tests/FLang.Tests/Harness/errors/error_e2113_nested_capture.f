//! TEST: error_e2113_nested_capture
//! COMPILE-ERROR: E2113

// RFC-014 Phase 2 limitation: a closure that captures a name which an
// enclosing closure also captures is not yet supported. Tracked as a
// follow-up — E2113 surfaces the limitation as a clean diagnostic rather
// than an ICE during closure lowering.

pub fn main() i32 {
    let base = 10
    let outer = fn(x: i32) i32 {
        let inner = fn(y: i32) i32 { y + base }
        return inner(x) + base
    }
    return outer(10)
}
