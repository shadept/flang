//! TEST: autoderef_forloop_ref
//! EXIT: 138

import std.list

struct Node {
    value: i32
}

pub fn main() i32 {
    const a: Node = .{ value = 27 }
    const b: Node = .{ value = 42 }
    const c: Node = .{ value = 69 }

    let list: List(&Node)
    list.push(&a)
    list.push(&b)
    list.push(&c)

    let sum: i32 = 0
    for (node in list) {
        // node is &&Node, should auto-deref to access value
        sum = sum + node.value
    }

    // 27 + 42 + 69 = 138
    return sum
}
