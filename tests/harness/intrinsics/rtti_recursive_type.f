//! TEST: rtti_recursive_type
//! EXIT: 0

// A type that reaches itself through a type argument (`Tree` holds a `List(Tree)`) has a
// descriptor that cites itself; the static table links and reads back whole.

import core.rtti
import std.collections.list

type Tree = struct {
    kids: List(Tree)
    value: i32
}

pub fn main() i32 {
    const t = type_info(Tree)
    if t.fields.len != 2 {
        return 1
    }
    const kids = t.fields[0].type_info
    if kids.name != "List" {
        return 2
    }
    if kids.type_args.len != 1 {
        return 3
    }
    if kids.type_args[0] != t {
        return 5
    }
    if t.fields[1].type_info != type_info(i32) {
        return 4
    }
    return 0
}
