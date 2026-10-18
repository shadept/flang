//! TEST: error_e2111_foreign_fn_flang_fn
//! COMPILE-ERROR: E2111

// A FLang function takes the context and `env` C does not pass, so it is no `#foreign fn`
// (RFC-037).

#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)

fn by_asc(a: &u8, b: &u8) i32 {
    return (a as &i32).* - (b as &i32).*
}

pub fn main() i32 {
    let xs: [i32; 2] = [2, 1]
    qsort(&xs[0] as &u8, 2usize, 4usize, by_asc)
    return 0
}
