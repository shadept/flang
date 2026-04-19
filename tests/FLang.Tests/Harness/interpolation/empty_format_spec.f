//! TEST: interp_empty_format_spec
//! EXIT: 0
//! STDOUT: 42 / 42

// `{x:}` (empty spec) should dispatch to the spec-taking append overload
// with an empty string, producing the same output as `{x}` (no spec).

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let n = 42i32
    let with_spec = $"{n:}"
    defer with_spec.deinit()
    let no_spec = $"{n}"
    defer no_spec.deinit()

    print(with_spec.as_view())
    print(" / ")
    print(no_spec.as_view())
    return 0
}
