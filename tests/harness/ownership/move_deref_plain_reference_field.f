//! TEST: move_deref_plain_reference_field
//! COMPILE-ERROR: E2125 `move` takes from
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// A reference field without `owned` is a borrow the struct holds, not storage it owns: the
// declaring module gets no grant on it.
type View = struct {
    p: &FileHandle
}

fn take(self: &View) FileHandle {
    return move self.p.*
}

pub fn main() i32 {
    let h = open(3)
    let v = View { p = &h }
    return close(take(&v))
}
