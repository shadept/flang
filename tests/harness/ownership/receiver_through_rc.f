//! TEST: receiver_through_rc
//! COMPILE-ERROR: E2128 reached through a reference
//! EXIT: 1

import std.rc

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// `Rc.op_deref` hands out `&FileHandle`; consuming through it would move the value out from under
// every other holder.
pub fn main() i32 {
    let r = rc(open(3))
    defer r.deinit()
    return r.close()
}
