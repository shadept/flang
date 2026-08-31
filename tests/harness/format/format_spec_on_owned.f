//! TEST: format_spec_on_owned
//! EXIT: 0
//! STDOUT: [  ab][cd  ]

// The spec-taking `OwnedString` and `StringBuilder` appends pad like `String`
// does. The OwnedString overload consumes its argument, as the unspecced one
// already did.

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let out = string_builder(32)
    defer out.deinit()

    out.append("[")
    out.append(from_view("ab"), ">4")

    let inner = string_builder(8)
    defer inner.deinit()
    inner.append("cd")

    out.append("][")
    out.append(inner, "<4")
    out.append("]")

    println(out.as_view())
    return 0
}
