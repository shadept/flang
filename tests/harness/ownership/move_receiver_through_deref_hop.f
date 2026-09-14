//! TEST: move_receiver_through_deref_hop
//! COMPILE-ERROR: E2128
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

type Wrap = struct {
    inner: FileHandle
}

fn op_deref(self: &Wrap) &FileHandle {
    return &self.inner
}

// Nor through an `op_deref` hop.
pub fn main() i32 {
    let w = Wrap { inner = open(3) }
    return w.close()               // error E2128
}
