//! TEST: interp_nested_interp
//! EXIT: 0
//! STDOUT: outer[inner=42] end

// Nested `$"..."` inside a hole. The inner interp evaluates to an OwnedString
// temporary; the outer `append` copies its bytes. The inner temporary's
// buffer is currently not reclaimed (see known-issues) — this test pins the
// output behavior, not the memory behavior.

import std.string_builder
import std.string
import core.io

pub fn main() i32 {
    let n = 42i32
    let msg = $"outer[{$"inner={n}"}] end"
    defer msg.deinit()
    print(msg.as_view())
    return 0
}
