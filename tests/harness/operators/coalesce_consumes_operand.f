//! TEST: coalesce_consumes_operand
//! COMPILE-ERROR: E2123
//! EXIT: 1

// `??` over a non-Option hands its left side to `op_try`, as `?` does: a non-copyable result is
// consumed, so a second use is a use after move.

import std.result

pub type Message = struct {
    owned code: i32
}

pub fn deinit(self: move Message) {}

fn fallback() Message {
    return Message { code = 0 }
}

pub fn main() i32 {
    let r: Result(Message, i32) = Ok(Message { code = 1 })
    let a: Message = r ?? fallback()
    let b: Message = r ?? fallback()
    a.deinit()
    b.deinit()
    return 0
}
