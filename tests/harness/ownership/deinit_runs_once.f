//! TEST: deinit_runs_once
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

let calls: i32 = 0

fn deinit(self: move FileHandle) {
    calls = calls + 1
}

pub fn main() i32 {
    {
        let h = open(3)
        defer h.deinit()
    }
    return calls
}
