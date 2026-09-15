//! TEST: move_parses_and_emits_nothing
//! EXIT: 42

// `move` emits no code: in every position that still takes it, over any place form, the value is
// unchanged.

type Handle = struct {
    fd: i32
}

fn take(h: Handle) i32 {
    return h.fd
}

pub fn main() i32 {
    let h = Handle { fd = 40i32 }

    // an argument carries no marker
    let a: i32 = take(h)

    // rebinding
    let h2 = Handle { fd = 1i32 }
    let h3 = move h2

    // field, index and dereference operands
    let n: i32 = move h3.fd
    let xs: [i32; 2] = [1i32, 0i32]
    let e: i32 = move xs[0]
    let p: &i32 = &n
    let d: i32 = move p.*

    return a + e + d
}
