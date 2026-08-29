//! TEST: defer_nested_block_scope
//! EXIT: 3
//! SKIP: RFC-027 not implemented

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

fn deinit(self: FileHandle) {}

// A defer fires at the end of ITS block, so the move is confined there.
pub fn main() i32 {
    let outer = open(3)
    {
        let inner = open(4)
        defer (move inner).deinit()
    }
    return close(move outer)
}
