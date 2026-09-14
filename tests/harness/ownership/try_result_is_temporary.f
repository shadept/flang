//! TEST: try_result_is_temporary
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

type Res = enum {
    Good(FileHandle)
    Bad(i32)
}

fn get(n: i32) Res {
    if n > 0 {
        return Res.Good(open(n))
    }
    return Res.Bad(n)
}

fn op_try(self: move Res) TryResult(FileHandle, Res) {
    return self match {
        Good(h) => TryResult.Continue(move h)
        Bad(n) => TryResult.Return(Res.Bad(n))
    }
}

fn peek(h: FileHandle) i32 {
    return h.fd
}

// The payload `?` yields is a temporary like any call result.
fn run() Res {
    let n = peek(get(3)?)          // error E2132
    return Res.Bad(n)
}

pub fn main() i32 {
    return 0
}
