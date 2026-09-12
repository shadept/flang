//! TEST: lambda_param_field_call_bound_local
//! EXIT: 0

// The companion of lambda_param_option_field_method: the method call on the open parameter's field
// is parked, and its placeholder result is bound to a local and used afterwards. The placeholder
// has to be unified with the resolved call type when the parked call is redone, or the local keeps
// an open var into layout. `is_some` never touches the payload, so nothing else pins `$T`.

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
        let present = entry.prev.is_some()
        let value = entry.prev.unwrap_or(0u32)
        if present { value } else { 1u32 }
    }, Undo { key = 1u32, prev = Some(7u32) })
    if restored != 7u32 {
        return 1
    }
    return 0
}
