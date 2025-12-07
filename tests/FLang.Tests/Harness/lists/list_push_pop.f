//! TEST: list_push_pop
//! EXIT: 12

import core.list
import core.option

pub fn main() i32 {
    let list: List(i32) = list_new()
    list_push(&list, 3)
    list_push(&list, 4)
    list_push(&list, 5)

    let a: i32 = list_get(&list, 0)
    let b: i32 = list_get(&list, 1)
    let c_opt: i32? = list_pop(&list)
    let c: i32 = unwrap_or(c_opt, 0)

    return a + b + c
}
