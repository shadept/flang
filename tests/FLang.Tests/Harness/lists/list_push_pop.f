//! TEST: list_push_pop
//! EXIT: 12

import std.list
import std.option

pub fn main() i32 {
    let list: List(i32) = list_new(i32)
    list.push(3)
    list.push(4)
    list.push(5)

    let a: i32 = list.get(0)
    let b: i32 = list.get(1)
    let c_opt: i32? = list.pop()
    let c: i32 = unwrap_or(c_opt, 0)

    list.deinit()

    return a + b + c
}
