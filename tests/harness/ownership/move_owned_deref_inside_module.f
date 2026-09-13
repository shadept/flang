//! TEST: move_owned_deref_inside_module
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

type Cell = struct {
    owned p: &FileHandle
}

// A dereference of an `owned` field, inside the module declaring it, is a place `move` takes from.
pub fn main() i32 {
    let h = open(3)
    let c = Cell { p = &h }
    return close(move c.p.*)
}
