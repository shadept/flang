//! TEST: move_in_question_operator
//! COMPILE-ERROR: E2122
//! EXIT: 1
//! SKIP: RFC-027 not implemented

import std.result

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

fn checked(h: FileHandle) Result(i32, i32) {
    return Ok(h.fd)
}

fn run() Result(i32, i32) {
    let h = open(3)
    let n = checked(move h)?
    return Ok(h.fd + n)            // error E2122
}

pub fn main() i32 {
    return run().unwrap_or(0)
}
