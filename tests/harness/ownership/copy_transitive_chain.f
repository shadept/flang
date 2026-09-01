//! TEST: copy_transitive_chain
//! COMPILE-ERROR: E2124 field `inner` is `Inner`
//! EXIT: 1

type Inner = struct {
    owned fd: i32
}

// `Outer` is non-copyable only through `Inner`, so the diagnostic must print
// every hop of the derivation, not just the type that was copied.
type Outer = struct {
    inner: Inner
    tag: i32
}

pub fn main() i32 {
    let o = Outer { inner = .{ fd = 3 }, tag = 0 }
    let b = o
    return b.tag
}
