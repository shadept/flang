//! TEST: context_defaults
//! STDOUT: root
//! STDOUT: 7
//! STDOUT: 42
//! STDOUT: true
//! EXIT: 0

// Every field starts at its declared default: a literal, a string, the address of a module
// constant, a function name and a payload-less variant.

import std.io.print

type Mode = enum {
    Quiet
    Loud
}

type Limits = struct {
    max: i32
}

const default_limits: Limits = Limits { max = 42 }

fn seven() i32 {
    return 7
}

context name: String = "root"
context count: fn() i32 = seven
context limits: &Limits = &default_limits
context mode: Mode = Mode.Loud

pub fn main() i32 {
    println(context.name)
    const f: fn() i32 = context.count
    println(f())
    println(context.limits.max)
    const loud: bool = context.mode match {
        Loud => true
        Quiet => false
    }
    println(loud)
    return 0
}
