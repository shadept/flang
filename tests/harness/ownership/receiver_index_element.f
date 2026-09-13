//! TEST: receiver_index_element
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

// An index receiver marks nothing, like `move xs[0]`: the element left the array unchecked.
pub fn main() i32 {
    let xs = [open(3)]
    return xs[0].close()
}
