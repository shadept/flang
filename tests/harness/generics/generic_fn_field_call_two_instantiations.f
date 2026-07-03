//! TEST: generic_fn_field_call_two_instantiations
//! EXIT: 0

// Regression: invoking a generic struct's `fn(&T)` field inside a generic body
// must substitute the instance's type args, not unify the definition's shared
// type-param TypeVar. Binding that var corrupted later monomorphisation, leaking
// `$T` into generated C once the generic was instantiated for two types.

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

// Uncalled, but its body is still validated — `self.cleanup(&v)` is the trigger.
fn dispose(self: &Wrap($T)) {
    self.val match {
        Some(v) => self.cleanup(&v),
        None => {}
    }
}

fn take(self: &Wrap($T)) T {
    return self.val match {
        Some(x) => x,
        None => panic("none")
    }
}

pub fn main() i32 {
    let f = Foo { x = 1i32 }
    let wf = mk(&f, fn(p: &&Foo) {})
    if take(&wf).x != 1i32 { return 1 }

    let b = Bar { y = 2i32 }
    let wb = mk(&b, fn(p: &&Bar) {})
    if take(&wb).y != 2i32 { return 2 }

    return 0
}
