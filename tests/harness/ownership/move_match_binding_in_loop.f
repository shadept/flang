//! TEST: move_match_binding_in_loop
//! EXIT: 6

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// A match arm's pattern binding is declared where the arm matches, so it is a
// new binding on every iteration and the back edge carries no move into it.
pub fn main() i32 {
    let total: i32 = 0
    let i: i32 = 0
    while i < 2 {
        let f = Some(open(3)) match {
            Some(v) => move v
            None => open(0)
        }
        total = total + close(move f)
        i = i + 1
    }
    return total
}
