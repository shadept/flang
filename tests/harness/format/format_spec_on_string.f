//! TEST: format_spec_on_string
//! EXIT: 0
//! STDOUT: [    hi][hi    ][..hi..][hi]
//! STDOUT: [   ok][o    ][k!]

// Text takes the same [fill][align][0][width] spec the numeric appenders do,
// with width a byte-count minimum. Wider text is emitted whole.

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let name = "hi"
    let msg = $"[{name:>6}][{name:<6}][{name:.^6}][{name:1}]"
    defer msg.deinit()
    println(msg.as_view())

    let sb = string_builder(32)
    defer sb.deinit()
    sb.append("[")
    sb.append("ok", ">5")
    sb.append("][")
    sb.append('o', "<5")
    sb.append("][")
    sb.append("k!", "")
    sb.append("]")
    println(sb.as_view())
    return 0
}
