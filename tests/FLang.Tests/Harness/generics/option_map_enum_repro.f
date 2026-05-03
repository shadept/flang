//! TEST: option_map_enum_repro
//! EXIT: 0
//! STDOUT: 2

import std.option
import std.list

type MyVal = enum {
    Null
    Num(f64)
    Arr(List(MyVal))
}

fn extract(v: MyVal) i32 {
    v match {
        Null => 0,
        Num(n) => n as i32,
        Arr(_) => 99,
    }
}

pub fn main() i32 {
    const opt: MyVal? = MyVal.Num(2.0)
    const mapped = opt.map(extract)
    if mapped.is_some() {
        println(mapped.unwrap())
    }
    return 0
}
