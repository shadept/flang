//! TEST: move_param_on_copyable
//! EXIT: 6

type Token = struct { id: i32 }

// `move` on a copyable type copies: the caller's binding stays live.
fn consume(t: move Token) i32 {
    return t.id
}

pub fn main() i32 {
    let t = Token { id = 3 }
    return consume(t) + t.id
}
