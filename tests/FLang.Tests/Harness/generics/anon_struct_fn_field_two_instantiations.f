//! TEST: anon_struct_fn_field_two_instantiations
//! EXIT: 0

// Regression: an anon-struct literal `.{}` coerced to a generic nominal with a
// function-pointer field over the type parameter (`fn(&T)`) must substitute T
// per instantiation. Two instantiations once shared one template TypeVar via
// the anon-struct coercion rule, contaminating each other (E2071).

import std.option

type Foo = struct { x: i32 }
type Bar = struct { y: i32 }

type Wrap = struct(T) {
    val: T?
    cleanup: fn(&T) void
}

fn mk(v: $T, c: fn(&T) void) Wrap(T) {
    let some: T? = v
    return .{ val = some, cleanup = c }
}

fn take(self: &Wrap($T)) T {
    return self.val match {
        Some(x) => x,
        None => panic("none")
    }
}

pub fn main() i32 {
    let wf = mk(Foo { x = 1i32 }, fn(p: &Foo) {})
    if take(&wf).x != 1i32 { return 1 }

    let wb = mk(Bar { y = 2i32 }, fn(p: &Bar) {})
    if take(&wb).y != 2i32 { return 2 }

    return 0
}
