//! TEST: integer_widen_var_decl
//! EXIT: 0

// Implicit widening in a variable declaration: i32 -> i64 is allowed.

pub fn main() i32 {
    let x: i64 = 5i32       // widening — i32 fits into i64
    let y: u32 = 200u8       // widening — u8 fits into u32
    let z: usize = 100u16    // widening — u16 fits into usize
    if x != 5i64 { return 1 }
    if y != 200u32 { return 2 }
    if z != 100 { return 3 }
    return 0
}
