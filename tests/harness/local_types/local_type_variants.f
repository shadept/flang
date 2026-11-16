//! TEST: local_type_variants
//! EXIT: 42

// RFC-046: a local enum's bare variants resolve only in its scope; elsewhere the module-level enum
// declaring the same variant wins. A local enum naming the function's `$T` builds its nullary
// variant with the `T` in scope.

import std.collections.list

type Signal = enum {
    Go(i32)
    Halt
}

fn module_go() i32 {
    const s: Signal = Go(2)
    return s match {
        Go(n) => n
        Halt => 0
    }
}

fn first_or(xs: &List($T), fallback: T) T where T: copyable {
    type Found = enum {
        Has(T)
        Nothing
    }
    let f: Found = Nothing
    if xs.len > 0 {
        f = Has(xs[0])
    }
    return f match {
        Has(v) => v
        Nothing => fallback
    }
}

pub fn main() i32 {
    type Signal = enum {
        Go(i32)
        Wait
    }
    const s: Signal = Go(10)
    const local = s match {
        Go(n) => n
        Wait => 0
    }
    let xs: List(i32) = list(0)
    defer xs.deinit()
    const empty = first_or(&xs, 20)
    xs.push(10)
    return local + module_go() + empty + first_or(&xs, 0)
}
