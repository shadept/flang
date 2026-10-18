//! TEST: error_e2111_foreign_fn_capture
//! COMPILE-ERROR: E2111

// A `#foreign fn` is one C code pointer, with no room for a closure's captures (RFC-037).

#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)

pub fn main() i32 {
    let xs: [i32; 2] = [2, 1]
    let dir: i32 = -1
    qsort(&xs[0] as &u8, 2usize, 4usize, { a: &u8, b: &u8 => dir * ((a as &i32).* - (b as &i32).*) })
    return 0
}
