//! TEST: rvalue_operator_result
//! COMPILE-ERROR: E2132
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn op_add(a: FileHandle, b: FileHandle) FileHandle {
    return .{ fd = a.fd + b.fd }
}

fn get(h: FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let a = open(1)
    let b = open(2)
    return get(a + b)                  // error E2132: `op_add(a, b)` reaches no owner
}
