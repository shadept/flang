//! TEST: option_map_enum_repro
//! EXIT: 0
//! STDOUT: 2

import std.collections.list
import std.io.print
import std.option

type MyVal = enum {
    Null
    Num(f64)
    Arr(List(MyVal))
}

fn extract(v: MyVal) i32 {
    v match {
        Null => 0
        Num(n) => n as i32
        Arr(_) => 99
    }
}

pub fn main() i32 {
    const opt: MyVal? = Some(MyVal.Num(2.0))
    // Pinned: `$U` would otherwise take the type of `println`'s first concrete overload (see
    // docs/known-issues.md, "A `$F` Callback Parameter Is Pinned by Luck").
    const mapped: Option(i32) = opt.map(extract)
    if mapped.is_some() {
        println(mapped.unwrap())
    }
    return 0
}
