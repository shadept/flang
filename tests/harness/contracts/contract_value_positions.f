//! TEST: contract_value_positions
//! COMPILE-ERROR: E2138
//! EXIT: 1

import std.collections.list
import std.option

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Holder = struct {
    it: Iter // error E2138: a field needs a value of the contract
}

fn many(xs: List(Iter)) {} // error E2138: a type argument

fn make() Iter { // error E2138: a return type
    return 0
}

pub fn main() i32 {
    return 0
}
