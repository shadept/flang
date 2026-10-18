//! TEST: foreign_fn_qsort
//! EXIT: 0

// C calls back into FLang through `#foreign fn` (RFC-037): a `#foreign fn` declared with a body, a
// non-capturing lambda, and a libc function held as a value, each one C code pointer.

#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)
#foreign fn abs(x: i32) i32

type Compare = #foreign fn(&u8, &u8) i32

type Hooks = #foreign struct {
    magnitude: #foreign fn(i32) i32
}

fn read(p: &u8) i32 {
    return (p as &i32).*
}

// Runs under the root context, and calls FLang as any body does.
#foreign fn by_desc(a: &u8, b: &u8) i32 {
    return read(b) - read(a)
}

pub fn main() i32 {
    let xs: [i32; 4] = [3, 1, 4, 2]
    const base: &u8 = &xs[0] as &u8
    const desc: Compare = by_desc
    qsort(base, 4usize, 4usize, desc)
    if xs[0] != 4 or xs[3] != 1 {
        return 1
    }
    qsort(base, 4usize, 4usize, { a: &u8, b: &u8 => read(a) - read(b) })
    if xs[0] != 1 or xs[3] != 4 {
        return 2
    }
    const h: Hooks = Hooks { magnitude = abs }
    return h.magnitude(-7i32) - 7
}
