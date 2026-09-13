//! TEST: move_owned_index_inside_module
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

// A buffer of handles: `ptr` is `owned`, so the elements behind it are this module's to take out.
type Buf = struct {
    owned ptr: &FileHandle
    len: usize
}

// `(self.ptr + i).*` is one element of the buffer an `owned` pointer field owns: the operand table
// admits it inside the declaring module (RFC-032).
pub fn main() i32 {
    let arr = [open(3), open(4)]
    let b = Buf { ptr = &arr[0], len = 2 }
    return close(move (b.ptr + 1usize).*)
}
