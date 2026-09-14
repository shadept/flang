//! TEST: try_operand_reads
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

fn op_try(self: Res) TryResult(FileHandle, Res) {
    return self match {
        Good(h) => TryResult.Continue(move h)
        Bad(n) => TryResult.Return(Res.Bad(n))
    }
}

// `e?` is `op_try(e)`: a read-only parameter, so the temporary reaches no owner.
fn run() Res {
    let h = get(3)?                // error E2132
    return Res.Good(move h)
}

pub fn main() i32 {
    return 0
}
