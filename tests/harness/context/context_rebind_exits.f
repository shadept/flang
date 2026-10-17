//! TEST: context_rebind_exits
//! STDOUT: in 3
//! STDOUT: out 0
//! STDOUT: in 1
//! STDOUT: out 0
//! STDOUT: in 2
//! STDOUT: out 0
//! EXIT: 0

// `return`, `?` and `break` leave a rebind body like any block: the defers on the way out run under
// the context current where each was written.

import std.io.print
import std.option
import std.string_builder

context level: i32 = 0

fn note(tag: String) {
    println($"{tag} {context.level}")
}

fn returns() i32 {
    defer note("out")
    context(level = 3i32) {
        defer note("in")
        return context.level
    }
    return -1
}

fn half(x: i32) i32? {
    if x % 2 == 0 {
        return Some(x / 2)
    }
    return null
}

fn tries() i32? {
    defer note("out")
    const v: i32 = context(level = 1i32) {
        defer note("in")
        half(3)?
    }
    return Some(v)
}

fn breaks() i32 {
    let n: i32 = 0
    loop {
        defer note("out")
        context(level = 2i32) {
            defer note("in")
            n = context.level
            break
        }
    }
    return n
}

pub fn main() i32 {
    if returns() != 3 {
        return 1
    }
    if tries().is_some() {
        return 2
    }
    if breaks() != 2 {
        return 3
    }
    return 0
}
