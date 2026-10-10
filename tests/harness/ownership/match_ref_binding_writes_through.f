//! TEST: match_ref_binding_writes_through
//! EXIT: 3

import std.collections.list
import std.option

// A binding into storage behind a reference names that storage: a push reaches the matched value.
fn grow(o: &Option(List(i32))) {
    o.* match {
        Some(v) => v.push(3)
        None => {}
    }
}

pub fn main() i32 {
    let xs: List(i32) = list(1)
    xs.push(1)
    xs.push(2)
    let o: List(i32)? = Some(move xs)
    grow(&o)
    const n = o match {
        Some(v) => v.len as i32
        None => 0
    }
    o.deinit()
    return n
}
