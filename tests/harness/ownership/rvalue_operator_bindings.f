//! TEST: rvalue_operator_bindings
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

// Operands are `T` parameters: comparing two owners leaves both live.
pub fn main() i32 {
    let a = open(3)
    let b = open(3)
    if a == b {
        return a.close() + b.close() - 5
    }
    return 0
}
