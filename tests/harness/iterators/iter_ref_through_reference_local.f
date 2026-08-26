//! TEST: iter_ref_through_reference_local
//! EXIT: 6

import std.dict
import std.list
import std.option

pub fn main() i32 {
    let d: Dict(String, List(i32)) = dict()
    let xs: List(i32) = list(3)
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    d.set("k", xs)

    // The local holds a reference to the stored list; iterating it by
    // reference must borrow the pointee, not the local's own address.
    let lst = d.get_ref("k").unwrap()
    let sum: i32 = 0
    for &x in lst {
        sum = sum + x.*
    }
    return sum
}
