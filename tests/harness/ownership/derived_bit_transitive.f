//! TEST: derived_bit_transitive
//! EXIT: 3

type Inner = struct {
    owned fd: i32
}

// `Outer` is non-copyable because `Inner` is, with no `owned` of its own.
type Outer = struct {
    inner: Inner
    tag: i32
}

fn consume(o: Outer) i32 {
    return o.inner.fd
}

pub fn main() i32 {
    let o = Outer { inner = .{ fd = 3 }, tag = 0 }
    return consume(move o)
}
