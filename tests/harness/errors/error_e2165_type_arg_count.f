//! TEST: error_e2165_type_arg_count
//! COMPILE-ERROR: E2165

// Type arguments must match the parameters the named type declares: none on a primitive, an alias
// of a non-generic type, or a non-generic struct; exactly as many as a generic one declares.
type Word = i32
type Point = struct {
    x: i32
}
type Box = struct(T) {
    v: T
}

pub fn main() i32 {
    const a: i32(u8) = 1 // error[E2165]
    const b: Word(u8) = 2 // error[E2165]
    const p: Point(u8) = Point { x = 3 } // error[E2165]
    const q: Box(i32, u8) = Box(i32) { v = 4 } // error[E2165]
    return a + b
}
