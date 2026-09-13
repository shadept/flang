//! TEST: move_parses_and_emits_nothing
//! EXIT: 42

// `move` emits no code: it marks a transfer and leaves the value unchanged, in every position the
// operand table admits (spec 3.6) - a binding and a field path here.

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

    // field operand
    let n: i32 = move h3.fd

    return a + n + 1
}
