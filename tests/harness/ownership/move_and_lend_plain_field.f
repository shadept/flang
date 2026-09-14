//! TEST: move_and_lend_plain_field
//! EXIT: 4

type Conn = struct {
    owned fd: i32
    id: i32
}

fn take(n: i32, c: move Conn) i32 {
    return c.fd + n
}

// `id` is not `owned`: the argument is a copy of plain data.
pub fn main() i32 {
    let c = Conn { fd = 3, id = 1 }
    return take(c.id, c)
}
