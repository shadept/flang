//! TEST: generics_overload_structural_specificity
//! EXIT: 0

// Structural specificity ranks overloads that take the arguments as written: a declared parameter
// carrying concrete type constructors (`Pair($A,$B)`) is a stricter match than an unconstrained
// catch-all (`$T`), even though the structured signature quantifies MORE type vars. `Dict`'s
// methods are reached through `op_deref` when no catch-all takes the receiver as written.

import std.collections.dict
import std.collections.list
import std.option

pub type Pair = struct(A, B) {
    a: A
    b: B
}

fn which(x: Pair($A, $B)) i32 { return 1 }
fn which(x: $T) i32 { return 2 }

pub fn main() i32 {
    let p: Pair(i32, i32) = Pair(i32, i32) { a = 1i32, b = 2i32 }
    if which(p) != 1 {
        return 1
    }
    if which(3i32) != 2 {
        return 2
    }

    // Dict's methods, reached through `op_deref`.
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 10i32)
    d.set(2u32, 21i32)
    let evens = d.filter(fn(k, v) { v % 2 == 0 })
    defer evens.deinit()
    if evens.len() != 1 {
        return 3
    }
    if !d.any(fn(k, v) { v > 20 }) {
        return 4
    }
    if d.count(fn(k, v) { v > 5 }) != 2 {
        return 5
    }

    return 0
}
