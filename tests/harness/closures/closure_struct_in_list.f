//! TEST: closure_struct_in_list
//! EXIT: 60

// Struct-wrapped closures from one lambda site share a nominal, so they are a homogeneous element
// type. Each captures `scale` by reference, and `scale` outlives the list.

import std.collections.list

type Thunk = struct(F) {
    f: F
}

fn thunk(f: move $F) Thunk(F) where F: fn() i32 {
    return .{ f = move f }
}

pub fn main() i32 {
    let scale = 20i32
    let xs = list(3)
    defer xs.deinit()
    for _i in 0..3usize {
        xs.push(thunk { => scale })
    }
    let total = 0i32
    for j in 0..xs.len {
        total = total + xs[j].f()
    }
    return total
}
