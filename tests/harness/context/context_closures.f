//! TEST: context_closures
//! STDOUT: caller
//! STDOUT: creator
//! EXIT: 0

// A closure does not capture the context: it runs under whoever calls it. Capturing a copy and
// rebinding to it inside the body runs it under its creator's.

import std.io.print

context who: String = "root"

fn run(f: $F) where F: fn() {
    context(who = "caller") {
        f()
    }
}

pub fn main() i32 {
    context(who = "creator") {
        const saved: Context = context
        run(fn() { println(context.who) })
        run(fn() {
            context(saved) {
                println(context.who)
            }
        })
    }
    return 0
}
