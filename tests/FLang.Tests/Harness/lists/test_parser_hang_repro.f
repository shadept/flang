//! TEST: test_parser_hang_repro
//! COMPILE-ERROR: E2004

// Named struct construction syntax (e.g., TypeName(TypeArg) { ... }) is planned
// but not yet implemented. Currently gives a semantic error.
// Workaround: use anonymous struct syntax with type annotation:
//   let x: Foo(i32) = .{ value = 5 }

struct Foo(T) {
    value: T
}

pub fn main() i32 {
    // Not yet supported: TypeName(TypeArg) { fields }
    let x = Foo(i32) { value = 5 }
    return 0
}
