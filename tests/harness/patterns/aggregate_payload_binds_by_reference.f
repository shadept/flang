//! TEST: aggregate_payload_binds_by_reference
//! STDOUT: 1
//! STDOUT: 2
//! STDOUT: 7
//! EXIT: 0
import core.io
import std.list
import std.option

type Holder = enum {
    Empty
    Items(List(i32))
}

// A payload binding names the scrutinee's own storage, so `&xs` is a pointer into the enum rather
// than into a copy that dies with this frame.
fn items_of(h: &Holder) &List(i32)? {
    return h.* match { Items(xs) => Some(&xs), else => null }
}

// Writing through the binding reaches the scrutinee.
fn push_seven(h: &Holder) {
    h.* match {
        Items(xs) => xs.push(7i32)
        else => {}
    }
}

pub fn main() i32 {
    let xs: List(i32) = list(4)
    xs.push(1i32)
    let h: Holder = Holder.Items(xs)

    const got: &List(i32)? = items_of(&h)
    if got.is_none() {
        return 1
    }
    got.unwrap().push(2i32)
    push_seven(&h)

    const items: &List(i32) = items_of(&h).unwrap()
    for i in 0..items.len {
        println(items[i])
    }
    return 0
}
