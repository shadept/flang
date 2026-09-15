//! TEST: where_copyable_rejects
//! COMPILE-ERROR: E2134 requires `T: copyable`
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn twice(x: $T) T where T: copyable {
    let a = x
    return a
}

// The bound is checked where the call binds `T`, and names why the argument does not copy.
pub fn main() i32 {
    const h = open(3)
    const g = twice(h)             // error E2134
    return 0
}
