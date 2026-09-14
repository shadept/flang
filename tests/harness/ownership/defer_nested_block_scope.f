//! TEST: defer_nested_block_scope
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn deinit(self: move FileHandle) {}

// A defer fires at the end of ITS block, so the move is confined there.
// A call directly before a bare block parses as a generic struct construction
// (docs/known-issues.md), so the block leads here.
pub fn main() i32 {
    {
        let inner = open(4)
        defer inner.deinit()
    }
    let outer = open(3)
    return outer.close()
}
