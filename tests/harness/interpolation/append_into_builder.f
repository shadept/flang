//! TEST: interp_append_into_builder
//! EXIT: 0
//! STDOUT: error[E0042]: unresolved `name` at 10:5

import std.io.print
import std.string
import std.string_builder

pub fn main() i32 {
    let sb = string_builder(64)
    defer sb.deinit()

    let code = 42i32
    let name = "name"
    let line = 10i32
    let col = 5i32
    $sb"error[E{code:04}]: unresolved `{name}` at {line}:{col}"

    print(sb.as_view())
    return 0
}
