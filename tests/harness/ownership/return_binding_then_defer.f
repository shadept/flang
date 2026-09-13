//! TEST: return_binding_then_defer
//! COMPILE-ERROR: E2123 was moved
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

fn deinit(self: FileHandle) {}

// The inferred move on `return h` happens before the defer runs, like `return move h`.
fn make() FileHandle {
    let h = open(3)
    defer h.deinit()
    return h                       // error E2123: the defer runs on a moved binding
}

pub fn main() i32 {
    let h = make()
    return h.close()
}
