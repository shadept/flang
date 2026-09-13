//! TEST: move_owned_pointer_copied_to_local
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

type Buf = struct {
    owned ptr: &FileHandle
    len: usize
}

// The grant is on the `owned` field as written, not on the pointer's value: a local holding the
// same address is a plain reference again, even inside the declaring module.
fn take_first(self: &Buf) FileHandle {
    let q = self.ptr
    return move q.*
}

pub fn main() i32 {
    let arr = [open(3)]
    let b = Buf { ptr = &arr[0], len = 1 }
    return close(take_first(&b))
}
