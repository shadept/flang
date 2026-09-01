//! TEST: reinit_in_every_match_arm
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// Every arm reinitializes the moved binding, so it is live at the merge. A merge seeded with the
// state the arms ran from would carry the move past the arms that undid it.
pub fn main() i32 {
    let h = open(1)
    close(move h)
    let k: i32 = 0
    k match {
        0i32 => {
            h = open(3)
        }
        else => {
            h = open(4)
        }
    }
    return close(move h)
}
