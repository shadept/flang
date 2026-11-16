//! TEST: local_type_recursive
//! EXIT: 42

// RFC-046: a local struct names itself and a sibling declared after it; `type_info` and a test body
// see local types; a directive applies to a local type.

import std.option
import std.test

fn depth() i32 {
    type Link = struct {
        value: i32
        next: &Link?
        tag: Tag
    }
    #allow(W2001)
    type Tag = enum { Leaf, Inner }
    const leaf = Link { value = 20, next = null, tag = Leaf }
    const root = Link { value = 20, next = Some(&leaf), tag = Inner }
    return root.value + root.next.unwrap().value
}

fn local_name() String {
    type Widget = struct { a: i32 }
    return type_info(Widget).name
}

test "a test body declares a local type" {
    type Probe = struct { n: i32 }
    const p = Probe { n = 1 }
    assert_true(p.n == 1, "local type field")
}

pub fn main() i32 {
    const named_right = local_name() == "Widget"
    return depth() + if named_right { 2 } else { 0 }
}
