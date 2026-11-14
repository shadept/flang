//! TEST: foreign_opaque
//! STDOUT: 42

// An empty `#foreign struct` is an incomplete C type: FLang only ever holds it behind a reference.

import std.io.print
import std.option

import _foreign_shim

pub fn main() i32 {
    const c = counter_new(40)
    if c.is_none() {
        return 1
    }
    const h: &Counter = c.unwrap()
    counter_add(h, 2)
    println(counter_get(h))
    counter_free(h)
    return 0
}
