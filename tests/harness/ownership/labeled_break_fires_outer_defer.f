//! TEST: labeled_break_fires_outer_defer
//! COMPILE-ERROR: E2123
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

fn deinit(self: move FileHandle) {}

// `break outer` fires the outer body's defers on its way out, so the move happens on that path.
pub fn main() i32 {
    let h = open(3)
    outer: loop {
        defer h.deinit()
        for _i in 0..2 as i32 {
            break outer
        }
    }
    return h.close() // error E2123
}
