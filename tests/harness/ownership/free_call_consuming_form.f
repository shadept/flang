//! TEST: free_call_consuming_form
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn deinit(self: move FileHandle) {}

// The free-function form takes ownership as the receiver form does.
pub fn main() i32 {
    let h = open(3)
    let n = close(h)
    let g = open(4)
    deinit(g)
    return n
}
