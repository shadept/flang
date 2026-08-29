//! TEST: pattern_binding_borrows
//! EXIT: 3
//! SKIP: RFC-027 not implemented

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// An aggregate pattern binding names the scrutinee's storage (spec 7.5), so it
// is not a copy and needs no `move`.
pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    return o match {
        Some(h) => h.fd,
        None => 0,
    }
}
