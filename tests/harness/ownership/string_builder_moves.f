//! TEST: string_builder_moves
//! EXIT: 3

import std.string
import std.string_builder

type Doc = struct {
    body: StringBuilder
}

pub fn deinit(self: move Doc) {
    self.body.deinit()
}

// A builder moves into a struct and hands its buffer over with `to_string`.
pub fn main() i32 {
    let sb = string_builder(8)
    sb.append("abc")
    let d = Doc { body = move sb }
    let s = d.body.to_string()
    const n = s.len as i32
    s.deinit()
    d.deinit()
    return n
}
