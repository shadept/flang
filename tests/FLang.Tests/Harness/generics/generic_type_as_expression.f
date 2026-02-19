//! TEST: generic_type_as_expression
//! EXIT: 0

// Test that generic types can be used in expression context with type args:
//   TypeName(TypeArg) resolves as a type-as-value (RTTI), not a function call.

import std.allocator

type Pair = struct(T) {
    first: T
    second: T
}

pub fn main() i32 {
    // Generic type instantiation as type-as-value
    const pair_size = size_of(Pair(i32))
    if pair_size == 0 {
        return 1
    }

    // Should equal 2 * size_of(i32)
    if pair_size != size_of(i32) * 2 {
        return 2
    }

    // allocator.new with generic type arg
    const alloc = &global_allocator
    const p = alloc.new(Pair(i32))
    p.first = 10
    p.second = 20
    if p.first != 10 { return 3 }
    if p.second != 20 { return 4 }
    alloc.free(p)

    return 0
}
