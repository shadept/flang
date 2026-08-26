//! TEST: type_param_in_value_position
//! EXIT: 0

// A type parameter used as a value is a reified type, exactly as a bare
// concrete type name is. When `T` is still unresolved, handing back the raw
// parameter var instead lets a `Type($X)` parameter unify with it, binding
// `T` itself to `Type($X)` - after which every consumer sizes its storage by
// a zero-field struct.
//
// `elems` is the shape that exposes it: `T` is free on entry and only the
// pushed elements pin it, while `size_of(T)` is checked first.

import std.list
import std.option

fn elems(n: usize) List($T) {
    const width = size_of(T)
    if width == 0 { return list(0) }
    return list(n)
}

// `size_of(T)` inside a generic must report T's own width, not the width of
// the reified handle.
fn width_of(t: Type($T)) usize {
    return size_of(T)
}

pub fn main() i32 {
    let a: List(u32) = elems(4)
    defer a.deinit()
    a.push(7u32)
    a.push(9u32)
    if a.len != 2 { return 1 }
    if a[0] != 7u32 { return 2 }
    if a[1] != 9u32 { return 3 }

    // Unannotated: T is pinned only by what goes in.
    let b = elems(4)
    defer b.deinit()
    b.push(1234i64)
    if b[0] != 1234i64 { return 4 }

    // size_of on a concrete type name is unchanged.
    if size_of(u32) != 4 { return 5 }

    // And it agrees when reached through a type parameter.
    if width_of(u32) != 4 { return 6 }
    if width_of(i64) != 8 { return 7 }
    if width_of(u8) != 1 { return 8 }
    return 0
}
