//! TEST: const_shadows_fn_value
//! EXIT: 42

// A bare identifier in value position resolves to a visible module const even
// when an imported module also exports a FUNCTION of the same name (here
// `probe`). The stdlib hits this shape with `stdin` / `stdout`: consts in
// std.io.file, same-named accessor functions in std.process.

import _shadow_const
import _shadow_fn

pub fn main() i32 {
    return probe.tag_plus(2)
}
