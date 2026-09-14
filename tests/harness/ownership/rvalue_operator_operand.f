//! TEST: rvalue_operator_operand
//! COMPILE-ERROR: E2132
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

fn op_eq(a: FileHandle, b: FileHandle) bool {
    return a.fd == b.fd
}

pub fn main() i32 {
    if open(3) == open(3) {        // error E2132: operands are read
        return 1
    }
    return 0
}
