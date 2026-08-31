//! TEST: move_parses_and_emits_nothing
//! EXIT: 42

// `move` is transparent until RFC-028 enforcement lands: it marks a transfer and emits no code, so
// every position that accepts an lvalue accepts it and the value is unchanged.

type Handle = struct {
    fd: i32
}

fn take(h: Handle) i32 {
    return h.fd
}

pub fn main() i32 {
    let h = Handle { fd = 40i32 }

    // by-value argument
    let a: i32 = take(move h)

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
