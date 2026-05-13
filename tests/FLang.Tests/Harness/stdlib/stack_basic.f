//! TEST: stack_basic
//! EXIT: 0

import std.option
import std.stack

pub fn main() i32 {
    let s: Stack(i32) = stack(0)
    defer s.deinit()

    if !s.is_empty() { return 1 }
    if s.pop().is_some() { return 2 }
    if s.peek().is_some() { return 3 }

    s.push(10i32)
    s.push(20i32)
    s.push(30i32)

    if s.len() != 3 { return 4 }
    if s.peek().unwrap_or(0i32) != 30i32 { return 5 }
    if s.len() != 3 { return 6 }

    // peek_ref mutates the top in place
    s.peek_ref() match {
        Some(p) => p.* = 99i32,
        None => return 7
    }
    if s.pop().unwrap_or(0i32) != 99i32 { return 8 }
    if s.pop().unwrap_or(0i32) != 20i32 { return 9 }
    if s.pop().unwrap_or(0i32) != 10i32 { return 10 }
    if !s.is_empty() { return 11 }

    // clear preserves the buffer so subsequent pushes reuse it
    s.push(1i32)
    s.push(2i32)
    s.clear()
    if !s.is_empty() { return 12 }
    s.push(7i32)
    if s.pop().unwrap_or(0i32) != 7i32 { return 13 }

    // as_slice walks bottom-to-top
    s.push(1i32)
    s.push(2i32)
    s.push(3i32)
    let view = s.as_slice()
    if view.len != 3 { return 14 }
    if view[0] != 1i32 { return 15 }
    if view[2] != 3i32 { return 16 }

    return 0
}
