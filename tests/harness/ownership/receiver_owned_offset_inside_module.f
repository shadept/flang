//! TEST: receiver_owned_offset_inside_module
//! EXIT: 4

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

type Buf = struct {
    owned ptr: &FileHandle
    len: usize
}

// Inside the declaring module the element of an `owned` buffer is a place, as a receiver too.
fn close_last(self: &Buf) i32 {
    self.len = self.len - 1
    return (self.ptr + self.len).*.close()
}

pub fn main() i32 {
    let arr = [open(3), open(4)]
    let b = Buf { ptr = &arr[0], len = 2 }
    return close_last(&b)
}
