//! TEST: move_param_on_copyable
//! EXIT: 10

type Token = struct {
    id: i32
    tag: i32
}

// `move` on a copyable type copies: the caller's binding stays live, and a write in the callee
// lands in the callee's own copy.
fn consume(t: move Token) i32 {
    t.id = t.id + 1
    return t.id
}

pub fn main() i32 {
    let t = Token { id = 3, tag = 0 }
    return consume(t) + consume(t) + t.tag + t.id - 1
}
