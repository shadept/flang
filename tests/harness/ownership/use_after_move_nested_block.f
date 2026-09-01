//! TEST: use_after_move_nested_block
//! COMPILE-ERROR: E2123
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

// A call directly before a bare block parses as a generic struct construction
// (docs/known-issues.md), so the block leads here.
pub fn main() i32 {
    let h = FileHandle { fd = 3 }
    {
        close(move h)
    }
    return h.fd                        // error E2123
}
