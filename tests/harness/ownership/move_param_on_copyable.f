//! TEST: move_param_on_copyable
//! EXIT: 3
//! SKIP: RFC-027 not implemented

type Token = struct { id: i32 }

// A `move` parameter consumes, so the call site is required to say `move`
// even though `Token` is copyable. This is the one case where `move` on a
// copyable value is not W2004.
fn consume(t: move Token) i32 {
    return t.id
}

pub fn main() i32 {
    let t = Token { id = 3 }
    return consume(move t)
}
