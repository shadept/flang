//! TEST: try_operand_moves
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

fn run() Res {
    let a = get(3)?
    let r = get(4)
    let b = r?
    let c = r?                     // error E2123: `op_try` took `r`
    return Res.Good(move a)
}

pub fn main() i32 {
    return 0
}
