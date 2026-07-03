//! TEST: dict_constructor
//! EXIT: 7

// `dict(allocator?)` zero-inits a Dict and resolves the allocator once.
// Same shape as `list(capacity, allocator?)` — K and V are inferred from
// the call's expected type. Replaces the prior `let d: Dict(...); d.allocator = ...`
// pattern, which is now forbidden by E2114.

import std.dict
import std.option
import std.string

pub fn main() i32 {
    let d: Dict(String, OwnedString) = dict()
    defer d.deinit()

    d.set("hello", from_view("seven"))
    if d.len() != 1 { return 1 }

    const v = d.get("hello")
    if v.is_none() { return 2 }

    return 7i32
}
