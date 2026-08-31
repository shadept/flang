//! TEST: closure_struct_in_list
//! EXIT: 60

// Struct-wrapped closures from one lambda site share a nominal, so they are a
// homogeneous element type. Each push copies its own captured snapshot.

import std.list

type Thunk = struct(F) {
    f: F,
}

fn thunk(f: $F) Thunk(F) {
    return .{ f = f }
}

pub fn main() i32 {
    let xs = list(3)
    defer xs.deinit()

    for i in 0..3usize {
        const n = i as i32 + 1
        xs.push(thunk(fn() i32 { n * 10 }))
    }

    let total = 0i32
    for j in 0..xs.len {
        total = total + xs[j].f()
    }
    return total
}
