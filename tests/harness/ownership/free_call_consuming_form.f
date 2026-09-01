//! TEST: free_call_consuming_form
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

fn deinit(self: FileHandle) {}

// The one spelling a consuming call has.
pub fn main() i32 {
    let h = open(3)
    let n = close(move h)
    let g = open(4)
    deinit(move g)
    return n
}
