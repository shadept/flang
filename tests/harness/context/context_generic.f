//! TEST: context_generic
//! EXIT: 12

// A generic body reads the context of its caller; the context is not part of the instantiation.

context bias: i32 = 0

fn biased(x: $T) i32 {
    return context.bias + size_of(T) as i32
}

pub fn main() i32 {
    const a: i32 = context(bias = 4i32) { biased(1u8) }
    const b: i32 = biased(1u64)
    return a + b - 1
}
