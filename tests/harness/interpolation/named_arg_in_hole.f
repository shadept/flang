//! TEST: interp_named_arg_in_hole
//! EXIT: 0
//! STDOUT: sum=7

// Exercises the parser's named-arg peek (ident followed by `=`) from inside a
// hole. The lexer must treat the hole-internal `(` / `)` depth correctly so
// the peek doesn't prematurely exit hole mode.

import std.string_builder
import std.string
import core.io

fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    let msg = $"sum={add(a=3i32, b=4i32)}"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
