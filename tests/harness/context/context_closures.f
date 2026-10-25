//! TEST: context_closures
//! STDOUT: caller
//! STDOUT: creator
//! EXIT: 0

// A closure does not capture the context: it runs under whoever calls it. Capturing a field and
// rebinding to it inside the body runs it under the creator's value.

import std.io.print

context who: String = "root"

fn run(f: $F) where F: fn() {
    context(who = "caller") {
        f()
    }
}

pub fn main() i32 {
    context(who = "creator") {
        const who = context.who
        run { println(context.who) }
        run {
            context(who = who) {
                println(context.who)
            }
        }
    }
    return 0
}
