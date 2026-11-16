//! TEST: local_type_generic
//! EXIT: 42

// RFC-046: a local type may be generic, and may name its function's `$T`; each instantiation of the
// function has its own copy.

fn wrap(x: $T, n: i32) i32 where T: copyable {
    type Boxed = struct {
        value: T
        count: i32
    }
    type Pair = struct(A) {
        left: A
        right: T
    }
    const b = Boxed { value = x, count = n }
    const p = Pair(i32) { left = b.count, right = b.value }
    return p.left
}

fn size_of_local(x: $T) usize where T: copyable {
    type Holder = struct {
        held: T
    }
    const h = Holder { held = x }
    return size_of(Holder) + 0 * size_of(T)
}

pub fn main() i32 {
    const small: u8 = 1
    const big: u64 = 1
    const sizes_differ = size_of_local(small) < size_of_local(big)
    const extra = if sizes_differ { 2 } else { 0 }
    return wrap(true, 20) + wrap(1.5f64, 20) + extra
}
