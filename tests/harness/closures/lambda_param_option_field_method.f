//! TEST: lambda_param_option_field_method
//! EXIT: 0

// An unannotated lambda parameter whose type comes from the callee's `$F` slot, with the body
// calling a generic method (`is_some`, `unwrap`) on one of the parameter's Option fields. The
// parameter's type settles when the callee's specialization pins it, but the method calls were
// specialized earlier against the still-open field type, and that variable reaches layout
// unresolved: "unresolved type variable reached layout - checker bug". Annotating the parameter
// (`fn(entry: Undo)`) sidesteps it. docs/known-issues.md.

import std.option

type Undo = struct {
    key: u32
    prev: u32?
}

fn apply(f: $F, entry: Undo) u32 {
    return f(entry)
}

pub fn main() i32 {
    let restored = apply(fn(entry) {
        if entry.prev.is_some() {
            entry.prev.unwrap()
        } else {
            0u32
        }
    }, Undo { key = 1u32, prev = Some(7u32) })
    if restored != 7u32 {
        return 1
    }
    return 0
}
