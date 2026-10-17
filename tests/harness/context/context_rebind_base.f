//! TEST: context_rebind_base
//! STDOUT: a 1
//! STDOUT: b 1
//! STDOUT: a 2
//! STDOUT: root 0
//! EXIT: 0

// A positional argument is the base context; named fields override it. A saved copy outlives the
// rebind it was taken in.

import std.io.print
import std.option
import std.string_builder

context name: String = "root"
context level: i32 = 0

fn show() {
    println($"{context.name} {context.level}")
}

pub fn main() i32 {
    let saved: Context = context(name = "a", level = 1i32) { context }
    context(saved) { show() }
    context(saved, name = "b") { show() }
    context(saved, level = 2i32) { show() }
    show()
    return 0
}
