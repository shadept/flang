//! TEST: context_by_ref_receiver
//! EXIT: 0

// A method taking `&T` on a by-value context field borrows a copy: the current context is never
// written.

type Counter = struct {
    n: i32
}

fn bump(c: &Counter) i32 {
    c.n = c.n + 1
    return c.n
}

context counter: Counter = Counter { n = 0 }

pub fn main() i32 {
    if context.counter.bump() != 1 {
        return 1
    }
    if context.counter.n != 0 {
        return 2
    }
    let mine: Context = context
    if mine.counter.bump() != 1 {
        return 3
    }
    return 0
}
